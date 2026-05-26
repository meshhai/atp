defmodule Atp.Transport.Runtime.SessionState do
  @moduledoc "Hydrated live-plane state for an active ATP session process."

  alias Atp.Transport.{Message, Session}

  @enforce_keys [
    :session_id,
    :status,
    :last_sequence,
    :initiator_agent_id,
    :recipient_agent_id,
    :opening_message_id,
    :started_at,
    :hydrated_at,
    :hydration_count
  ]
  defstruct [
    :session_id,
    :status,
    :last_sequence,
    :initiator_agent_id,
    :recipient_agent_id,
    :opening_message_id,
    :lifecycle_deadline_at,
    :lifecycle_timer_ref,
    :started_at,
    :hydrated_at,
    :hydration_count,
    :webhook_dispatch_owner,
    webhook_dispatch_queue: :queue.new(),
    webhook_dispatch_waiters: %{},
    webhook_dispatch_ticket_monitors: %{},
    webhook_dispatch_monitor_tickets: %{}
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          status: String.t(),
          last_sequence: non_neg_integer(),
          initiator_agent_id: String.t(),
          recipient_agent_id: String.t(),
          opening_message_id: String.t() | nil,
          lifecycle_deadline_at: DateTime.t() | nil,
          lifecycle_timer_ref: reference() | nil,
          started_at: DateTime.t(),
          hydrated_at: DateTime.t(),
          hydration_count: pos_integer(),
          webhook_dispatch_owner: {reference(), reference()} | nil,
          webhook_dispatch_queue: term(),
          webhook_dispatch_waiters: %{optional(reference()) => GenServer.from()},
          webhook_dispatch_ticket_monitors: %{optional(reference()) => reference()},
          webhook_dispatch_monitor_tickets: %{optional(reference()) => reference()}
        }

  @type summary :: %{
          required(:session_id) => String.t(),
          required(:pid) => pid(),
          required(:runtime_status) => :running,
          required(:session_status) => String.t(),
          required(:last_sequence) => non_neg_integer(),
          required(:lifecycle_timer_active) => boolean(),
          required(:lifecycle_deadline_at) => DateTime.t() | nil,
          required(:process_started_at) => DateTime.t(),
          required(:hydrated_at) => DateTime.t(),
          required(:hydration_count) => pos_integer()
        }

  @spec from_session(Session.t()) :: t()
  def from_session(%Session{} = session) do
    from_session(session, DateTime.utc_now(:microsecond))
  end

  @spec refresh_from_session(t(), Session.t()) :: t()
  def refresh_from_session(%__MODULE__{} = state, %Session{} = session) do
    refreshed_state = from_session(session, DateTime.utc_now(:microsecond))

    %__MODULE__{
      refreshed_state
      | started_at: state.started_at,
        hydration_count: state.hydration_count + 1,
        webhook_dispatch_owner: state.webhook_dispatch_owner,
        webhook_dispatch_queue: state.webhook_dispatch_queue,
        webhook_dispatch_waiters: state.webhook_dispatch_waiters,
        webhook_dispatch_ticket_monitors: state.webhook_dispatch_ticket_monitors,
        webhook_dispatch_monitor_tickets: state.webhook_dispatch_monitor_tickets
    }
  end

  @spec summary(t(), pid()) :: summary()
  def summary(%__MODULE__{} = state, pid) when is_pid(pid) do
    %{
      session_id: state.session_id,
      pid: pid,
      runtime_status: :running,
      session_status: state.status,
      last_sequence: state.last_sequence,
      lifecycle_timer_active: is_reference(state.lifecycle_timer_ref),
      lifecycle_deadline_at: state.lifecycle_deadline_at,
      process_started_at: state.started_at,
      hydrated_at: state.hydrated_at,
      hydration_count: state.hydration_count
    }
  end

  defp from_session(%Session{} = session, %DateTime{} = now) do
    %__MODULE__{
      session_id: session.id,
      status: session.status,
      last_sequence: session.last_sequence,
      initiator_agent_id: session.initiator_agent_id,
      recipient_agent_id: session.recipient_agent_id,
      opening_message_id: session.opening_message_id,
      lifecycle_deadline_at: lifecycle_deadline_at(session),
      lifecycle_timer_ref: nil,
      started_at: now,
      hydrated_at: now,
      hydration_count: 1
    }
  end

  defp lifecycle_deadline_at(%Session{
         status: "pending",
         opening_message: %Message{expires_at: %DateTime{} = expires_at}
       }) do
    expires_at
  end

  defp lifecycle_deadline_at(%Session{}), do: nil
end
