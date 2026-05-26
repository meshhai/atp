defmodule AtpWeb do
  @moduledoc false

  use Boundary,
    deps: [Atp],
    exports: [
      Endpoint,
      Router,
      APIResponse,
      ErrorJSON,
      AccountController,
      AgentController,
      DeliveryController,
      InboxController,
      MessageController,
      SessionController,
      WebhookEndpointController,
      {Plugs, [Authenticate, RequireAccount, RequireAgent]}
    ]

  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  @spec controller() :: Macro.t()
  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
