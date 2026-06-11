defmodule AtpWeb.Router do
  use AtpWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :account_auth do
    plug(AtpWeb.Plugs.Authenticate)
    plug(AtpWeb.Plugs.RequireAccount)
  end

  pipeline :agent_auth do
    plug(AtpWeb.Plugs.Authenticate)
    plug(AtpWeb.Plugs.RequireAgent)
  end

  pipeline :principal_auth do
    plug(AtpWeb.Plugs.Authenticate)
  end

  scope "/", AtpWeb do
    pipe_through(:api)

    get("/health", HealthController, :show)
    get("/ready", ReadyController, :show)
  end

  scope "/api", AtpWeb do
    pipe_through(:api)

    post("/accounts", AccountController, :create)
  end

  scope "/api", AtpWeb do
    pipe_through([:api, :account_auth])

    post("/agents", AgentController, :create)
    get("/agents/:id", AgentController, :show)
    post("/agents/:id/keys", AgentController, :create_key)
  end

  scope "/api", AtpWeb do
    pipe_through([:api, :principal_auth])

    get("/messages/:id", MessageController, :show)
  end

  scope "/api", AtpWeb do
    pipe_through([:api, :agent_auth])

    post("/messages", MessageController, :create)
    post("/sessions", SessionController, :create)
    get("/sessions/:id", SessionController, :show)
    post("/sessions/:id/accept", SessionController, :accept)
    post("/sessions/:id/reject", SessionController, :reject)
    post("/sessions/:id/messages", SessionController, :create_message)
    put("/agents/:id/webhook_endpoint", WebhookEndpointController, :update)
    put("/agents/:id/sender_policies", SenderPolicyController, :upsert)
    post("/inbox/claims", InboxController, :create_claim)
    post("/deliveries/:id/acks", AckController, :create)
    post("/deliveries/:id/extend", DeliveryController, :extend)
  end
end
