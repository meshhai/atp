defmodule Atp do
  @moduledoc """
  ATP is the carrier layer for agents.

  This app owns the Agent Transport Protocol core database and identity
  boundary. It intentionally does not depend on product-domain modules.
  """

  use Boundary,
    deps: [],
    exports: [
      CLI,
      Identity,
      {Identity, [Account, AccountApiKey, Agent, AgentApiKey, IdempotencyKey]},
      Transport,
      {Transport,
       [
         Delivery,
         Message,
         MessageEnvelope,
         Session,
         WebhookAttempt,
         WebhookDelivery,
         WebhookDispatcher,
         WebhookSignature
       ]},
      Repo
    ]
end
