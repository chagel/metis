# Navigation rules for the Hotwire Native apps (clients/../metis-ios).
# Served from the server so rules can change without an app-store
# release; the app bundles a fallback copy for offline first-launch.
class Hotwire::PathConfigurationsController < ApplicationController
  skip_before_action :authenticate_user!

  IOS_RULES = [
    { patterns: [ ".*" ],
      properties: { context: "default", pull_to_refresh_enabled: true } },
    # Form screens present as native modals.
    { patterns: [ "/new$", "/edit$" ],
      properties: { context: "modal" } },
    # Top-level sections reached from the sidebar drawer (no native tab
    # bar): replace the stack root so switching between them stays flat
    # instead of pushing an ever-deeper back stack.
    { patterns: [ "^/$", "^/conversations$", "^/projects$", "^/board$", "^/settings$", "^/settings/profile$" ],
      properties: { presentation: "replace_root" } },
    # Auth replaces the stack root — no back-swiping into signed-in pages.
    { patterns: [ "/users/sign_in", "/users/sign_up", "/users/password" ],
      properties: { pull_to_refresh_enabled: false, presentation: "replace_root" } },
    # turbo-rails historical-location endpoints (recede_or_redirect_to & co).
    { patterns: [ "/recede_historical_location" ],
      properties: { presentation: "pop", context: "default" } },
    { patterns: [ "/refresh_historical_location" ],
      properties: { presentation: "refresh", context: "default" } },
    { patterns: [ "/resume_historical_location" ],
      properties: { presentation: "none", context: "default" } }
  ].freeze

  def ios
    render json: { settings: {}, rules: IOS_RULES }
  end
end
