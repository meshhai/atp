defmodule Atp.IdempotencyTest do
  use Atp.DataCase, async: false

  alias Atp.Identity
  alias Atp.Identity.{Account, Agent, AgentApiKey, Idempotency, IdempotencyKey}

  @encrypted_response_body_v1 "encrypted_v1"
  @response_body_salt "atp idempotency response body v1"

  test "concurrent retries reserve the key before side effects run" do
    account = create_account!()
    parent = self()
    release = make_ref()

    callback = fn ->
      send(parent, {:callback_started, self()})

      case wait_for_release(release) do
        :ok -> {:ok, 201, %{"reserved" => true}}
        {:error, reason} -> {:error, reason}
      end
    end

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          Idempotency.run(account, "POST /race", "race-key", %{"body" => true}, callback)
        end)
      end

    assert_receive {:callback_started, callback_pid}, 500
    refute_receive {:callback_started, _other_pid}, 100

    send(callback_pid, release)

    assert Task.await_many(tasks, 1_000) == [
             {:ok, 201, %{"reserved" => true}},
             {:ok, 201, %{"reserved" => true}}
           ]
  end

  test "encrypted replay responses remain readable after token max age" do
    account = create_account!()
    route = "POST /encrypted-replay"
    key = "encrypted-replay-key"
    params = %{"body" => true}
    response_body = %{"credential" => "secret-on-first-response"}

    assert {:ok, 201, ^response_body} =
             Idempotency.run(account, route, key, params, fn -> {:ok, 201, response_body} end)

    entry =
      Repo.get_by!(IdempotencyKey,
        account_id: account.id,
        principal_type: "account",
        principal_id: account.id,
        route: route,
        key: key
      )

    expired_response_body = %{
      "encoding" => @encrypted_response_body_v1,
      "ciphertext" =>
        Plug.Crypto.encrypt(response_secret_key_base(), @response_body_salt, response_body,
          max_age: 0
        )
    }

    entry
    |> IdempotencyKey.completion_changeset(%{
      response_status: 201,
      response_body: expired_response_body
    })
    |> Repo.update!()

    assert {:ok, 201, ^response_body} =
             Idempotency.run(account, route, key, params, fn ->
               flunk("idempotency replay should not call the callback")
             end)
  end

  test "idempotency rejects blank keys and unsupported principals" do
    account = create_account!()

    assert {:error, :idempotency_key_required} =
             Idempotency.run(account, "POST /blank-key", "   ", %{}, fn ->
               flunk("blank keys must reject before callback execution")
             end)

    assert {:error, :invalid_idempotency_principal} =
             Idempotency.run(:unsupported, "POST /bad-principal", "bad-principal", %{}, fn ->
               flunk("unsupported principals must reject before callback execution")
             end)
  end

  test "idempotency replays legacy map bodies and rejects unreadable encrypted bodies" do
    account = create_account!()
    params = %{"body" => true}

    assert {:ok, 201, %{"stored" => true}} =
             Idempotency.run(account, "POST /legacy-replay", "legacy-replay", params, fn ->
               {:ok, 201, %{"stored" => true}}
             end)

    rewrite_response_body!(account, "POST /legacy-replay", "legacy-replay", %{"legacy" => true})

    assert {:ok, 201, %{"legacy" => true}} =
             Idempotency.run(account, "POST /legacy-replay", "legacy-replay", params, fn ->
               flunk("idempotency replay should not call the callback")
             end)

    assert {:ok, 201, %{"stored" => true}} =
             Idempotency.run(account, "POST /non-map-replay", "non-map-replay", params, fn ->
               {:ok, 201, %{"stored" => true}}
             end)

    encrypted_non_map = %{
      "encoding" => @encrypted_response_body_v1,
      "ciphertext" =>
        Plug.Crypto.encrypt(response_secret_key_base(), @response_body_salt, "not a map",
          max_age: 0
        )
    }

    rewrite_response_body!(account, "POST /non-map-replay", "non-map-replay", encrypted_non_map)

    assert {:error, :idempotency_response_unreadable} =
             Idempotency.run(account, "POST /non-map-replay", "non-map-replay", params, fn ->
               flunk("idempotency replay should not call the callback")
             end)

    assert {:ok, 201, %{"stored" => true}} =
             Idempotency.run(account, "POST /garbled-replay", "garbled-replay", params, fn ->
               {:ok, 201, %{"stored" => true}}
             end)

    rewrite_response_body!(account, "POST /garbled-replay", "garbled-replay", %{
      "encoding" => @encrypted_response_body_v1,
      "ciphertext" => "not encrypted data"
    })

    assert {:error, :idempotency_response_unreadable} =
             Idempotency.run(account, "POST /garbled-replay", "garbled-replay", params, fn ->
               flunk("idempotency replay should not call the callback")
             end)
  end

  test "idempotency reports in-progress rows without replaying side effects" do
    account = create_account!()
    route = "POST /in-progress"
    key = "in-progress-key"
    params = %{"body" => true}

    %IdempotencyKey{
      id: "idem_in_progress",
      account_id: account.id,
      principal_id: account.id,
      principal_type: "account",
      key: key,
      route: route,
      request_hash: request_hash(params)
    }
    |> Repo.insert!()

    assert {:error, :idempotency_in_progress} =
             Idempotency.run(account, route, key, params, fn ->
               flunk("in-progress idempotency rows must not call the callback")
             end)

    assert {:error, :idempotency_in_progress} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               params,
               fn -> flunk("in-progress idempotency rows must not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("in-progress idempotency rows must not call after_commit")
               end
             )
  end

  test "after-commit idempotency persists the final committed response" do
    account = create_account!()
    route = "POST /after-commit"
    key = "after-commit-key"
    params = %{"body" => true}

    assert {:ok, 201, %{"final" => true}} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               params,
               fn -> {:ok, 202, %{"prepared" => true}, :commit_value} end,
               fn status, body, :commit_value ->
                 assert status == 202
                 assert body == %{"prepared" => true}

                 {:ok, 201, %{"final" => true}}
               end
             )

    assert {:ok, 201, %{"final" => true}} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               params,
               fn -> flunk("after-commit replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("after-commit replay should not call after_commit")
               end
             )

    assert {:error, :idempotency_conflict} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               %{"body" => "changed"},
               fn -> flunk("conflicting replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("conflicting replay should not call after_commit")
               end
             )

    assert {:ok, 201, %{"stored" => true}} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-unreadable",
               "after-commit-unreadable-key",
               params,
               fn -> {:ok, 201, %{"stored" => true}} end,
               fn _status, _body, _commit_value ->
                 flunk("plain callback results should not call after_commit")
               end
             )

    rewrite_response_body!(
      account,
      "POST /after-commit-unreadable",
      "after-commit-unreadable-key",
      %{
        "encoding" => @encrypted_response_body_v1,
        "ciphertext" => "not encrypted data"
      }
    )

    assert {:error, :idempotency_response_unreadable} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-unreadable",
               "after-commit-unreadable-key",
               params,
               fn -> flunk("unreadable replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("unreadable replay should not call after_commit")
               end
             )
  end

  test "after-commit idempotency remains pending while the final response is still running" do
    account = create_account!()
    route = "POST /after-commit-pending"
    key = "after-commit-pending-key"
    params = %{"body" => true}
    parent = self()
    release_after_commit = make_ref()

    task =
      Task.async(fn ->
        Idempotency.run_after_commit(
          account,
          route,
          key,
          params,
          fn -> {:ok, 202, %{"prepared" => true}, :commit_value} end,
          fn _status, _body, :commit_value ->
            send(parent, :after_commit_started)

            receive do
              ^release_after_commit -> {:ok, 201, %{"final" => true}}
            end
          end
        )
      end)

    assert_receive :after_commit_started, 500

    assert {:error, :idempotency_in_progress} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               params,
               fn -> flunk("pending after-commit replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("pending after-commit replay should not call after_commit")
               end
             )

    send(task.pid, release_after_commit)
    assert Task.await(task, 1_000) == {:ok, 201, %{"final" => true}}

    assert {:ok, 201, %{"final" => true}} =
             Idempotency.run_after_commit(
               account,
               route,
               key,
               params,
               fn -> flunk("completed after-commit replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("completed after-commit replay should not call after_commit")
               end
             )
  end

  test "after-commit idempotency supports plain results and closes failed after-commit rows" do
    account = create_account!()

    assert {:ok, 200, %{"plain" => true}} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-plain",
               "after-commit-plain-key",
               %{"body" => true},
               fn -> {:ok, 200, %{"plain" => true}} end,
               fn _status, _body, _commit_value ->
                 flunk("plain callback results should not call after_commit")
               end
             )

    assert {:error, :prepare_failed} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-prepare-error",
               "after-commit-prepare-error-key",
               %{"body" => true},
               fn -> {:error, :prepare_failed} end,
               fn _status, _body, _commit_value ->
                 flunk("failed callbacks should not call after_commit")
               end
             )

    assert {:ok, 202, %{"prepared" => true}} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-error",
               "after-commit-error-key",
               %{"body" => true},
               fn -> {:ok, 202, %{"prepared" => true}, :commit_value} end,
               fn 202, %{"prepared" => true}, :commit_value ->
                 assert {:error, :idempotency_in_progress} =
                          Idempotency.run_after_commit(
                            account,
                            "POST /after-commit-error",
                            "after-commit-error-key",
                            %{"body" => true},
                            fn ->
                              flunk("prepared after-commit replay should not call the callback")
                            end,
                            fn _status, _body, _commit_value ->
                              flunk("prepared after-commit replay should not call after_commit")
                            end
                          )

                 {:error, :after_commit_failed}
               end
             )

    assert {:ok, 202, %{"prepared" => true}} =
             Idempotency.run_after_commit(
               account,
               "POST /after-commit-error",
               "after-commit-error-key",
               %{"body" => true},
               fn -> flunk("after-commit fallback replay should not call the callback") end,
               fn _status, _body, _commit_value ->
                 flunk("after-commit fallback replay should not call after_commit")
               end
             )
  end

  test "idempotency key changeset declares persisted row constraints" do
    account = create_account!()

    changeset =
      IdempotencyKey.changeset(%IdempotencyKey{id: "idem_test"}, %{
        account_id: account.id,
        principal_id: account.id,
        principal_type: "account",
        key: "constraint-key",
        route: "POST /constraints",
        request_hash: String.duplicate("0", 64),
        response_status: 201,
        response_body: %{"ok" => true}
      })

    assert changeset.valid?
  end

  test "concurrent registrations enforce the active-agent plan limit transactionally" do
    account = create_account!()

    result_counts =
      1..3
      |> Task.async_stream(
        fn index ->
          Identity.register_agent(
            account,
            %{"display_name" => "Agent #{index}"},
            "concurrent-register-#{index}",
            "POST /api/agents"
          )
        end,
        max_concurrency: 3,
        timeout: :infinity
      )
      |> Enum.reduce(%{ok: 0, plan_limit_exceeded: 0}, fn
        {:ok, {:ok, 201, _agent}}, counts ->
          Map.update!(counts, :ok, &(&1 + 1))

        {:ok, {:error, :plan_limit_exceeded}}, counts ->
          Map.update!(counts, :plan_limit_exceeded, &(&1 + 1))
      end)

    assert result_counts == %{ok: 2, plan_limit_exceeded: 1}
    assert active_agent_count(account) == 2
  end

  test "concurrent key rotations serialize to exactly one active agent key" do
    account = create_account!()

    {:ok, 201, agent} =
      Identity.register_agent(account, %{}, "register-for-rotation", "POST /api/agents")

    rotated_key_ids =
      1..5
      |> Task.async_stream(
        fn index ->
          Identity.rotate_agent_key(account, agent["id"], %{}, "concurrent-rotate-#{index}")
        end,
        max_concurrency: 5,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, 201, %{"id" => id, "token" => "agk_" <> _token}}} -> id end)

    [active_key_id] = active_agent_key_ids(agent["id"])

    assert active_key_id in rotated_key_ids
  end

  defp create_account! do
    {:ok, account_response} = Identity.create_account(%{"name" => "Dev Network"})
    Atp.Repo.get!(Account, account_response["id"])
  end

  defp active_agent_count(%Account{} = account) do
    Agent
    |> where([agent], agent.account_id == ^account.id and agent.status == "active")
    |> Repo.aggregate(:count)
  end

  defp active_agent_key_ids(agent_id) do
    AgentApiKey
    |> where([key], key.agent_id == ^agent_id and is_nil(key.revoked_at))
    |> select([key], key.id)
    |> Repo.all()
  end

  defp response_secret_key_base do
    :atp
    |> Application.fetch_env!(Idempotency)
    |> Keyword.fetch!(:response_secret_key_base)
  end

  defp request_hash(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp rewrite_response_body!(%Account{} = account, route, key, response_body) do
    IdempotencyKey
    |> Repo.get_by!(
      account_id: account.id,
      principal_type: "account",
      principal_id: account.id,
      route: route,
      key: key
    )
    |> IdempotencyKey.completion_changeset(%{
      response_status: 201,
      response_body: response_body
    })
    |> Repo.update!()
  end

  defp wait_for_release(release) do
    receive do
      ^release -> :ok
    after
      1_000 -> {:error, :callback_not_released}
    end
  end
end
