# Settings UI for enrolled local machines (docs/local-bridge.md). Members
# view; admins enroll and revoke — same curation split as skills /
# connectors / projects.
class BridgesController < ApplicationController
  layout "settings"

  before_action :require_team_admin!, except: :index
  before_action :set_device, only: :destroy

  def index
    @devices = team.devices.order(created_at: :desc)
    @device = team.devices.new
  end

  def create
    @device = team.devices.new(device_params)
    @device.user = current_user
    @devices = team.devices.order(created_at: :desc)

    if @device.save
      # Shown once — the plaintext token is never stored or recoverable.
      @new_token = @device.plaintext_token
      flash.now[:notice] = "Device enrolled. Copy its token now — it won't be shown again."
      render :index
    else
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @device.destroy
    redirect_to bridges_path, notice: "#{@device.name} revoked."
  end

  private

  def team
    current_team
  end

  def set_device
    @device = team.devices.find(params[:id])
  end

  def device_params
    params.require(:device).permit(:name, :agent_kind)
  end
end
