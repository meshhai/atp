defmodule Atp.Transport.DurableLedger.PostgresContractTest do
  use Atp.Support.DurableLedgerContract,
    adapter: Atp.Transport.DurableLedger.Postgres,
    harness: Atp.Support.DurableLedgerContract.PostgresHarness
end
