require "test_helper"

class Settings::DeveloperControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "dev-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  test "show renders the developer page" do
    get developer_path
    assert_response :success
    assert_select ".settings-card-title", /Local bridge/
  end

  test "bridge_token generates a token and shows the manual setup with the plaintext once" do
    @user.update!(auto_claim_tasks: false)
    post developer_bridge_token_path
    assert_response :success
    assert @user.reload.bridge_token_digest.present?
    # In manual mode the all-in-one block installs the skill, points at the
    # MCP endpoint, and carries the freshly minted plaintext.
    assert_select ".bridge-paste", /mbt_/
    assert_select ".bridge-paste", %r{api/bridge/skill}
    assert_select ".bridge-paste", %r{api/bridge/mcp}
    assert_select ".bridge-paste", { text: /…/, count: 0 }, "plaintext, not redacted, on generation"
    assert_select ".bridge-status--fresh"

    # Instructions stay on a normal reload, but the plaintext is gone — the
    # block tells the user to regenerate rather than pasting a dead token.
    get developer_path
    assert_select ".bridge-paste", /Regenerate my bridge token/
    assert_select ".bridge-paste", { text: /mbt_…/, count: 0 }, "no dead redacted token pasted on reload"
    assert_select ".bridge-status--fresh", count: 0
  end

  test "auto mode shows the daemon setup block, with the live token only when fresh" do
    post developer_bridge_token_path               # auto is the default
    assert_select "input.bridge-switch-input[checked]", true, "auto-claim switch is on by default"
    assert_select ".bridge-tab .bridge-mode-dot--auto", true, "the auto tab is marked current"
    assert_select ".bridge-paste", /go install/
    assert_select ".bridge-paste", /metis install/
    assert_select ".bridge-paste", /"token": "mbt_/, "fresh generation embeds the live token"

    get developer_path
    assert_select ".bridge-paste", { text: /mbt_…/, count: 0 }, "no dead redacted token in the daemon config on reload"
    assert_select ".bridge-paste", /regenerate your token/
  end

  test "the bridge UI is fully translated in zh-CN — no missing keys leaking into markup" do
    @user.update!(language: "zh-CN")
    post developer_bridge_token_path               # auto is the default

    # A missing key renders an HTML translation_missing span; inside an
    # attribute (aria-label/title) it corrupts the markup and the paste
    # block renders garbage. Assert the real translations resolved instead.
    assert_select "span.translation_missing", count: 0
    assert_select ".bridge-switch-label", /自动认领任务/
    assert_select ".bridge-tab", /守护进程/
    assert_select ".bridge-tab", /MCP/
    assert_select ".token-copy[aria-label=?]", "复制设置说明到剪贴板"
    # The paste block holds only the setup text, never leaked button markup.
    assert_select ".bridge-paste", { text: /data-controller|aria-label/, count: 0 }
  end

  test "the claim-mode switch is hidden until a token exists, then on by default" do
    get developer_path
    assert_select ".bridge-switch", count: 0

    @user.generate_bridge_token!
    get developer_path
    assert_select ".bridge-switch"
    # Auto is the default — the switch is on.
    assert_select "input.bridge-switch-input[checked]"
  end

  test "bridge_prefs persists the auto-claim preference" do
    @user.generate_bridge_token!
    patch developer_bridge_prefs_path, params: { user: { auto_claim_tasks: "1" } }
    assert_redirected_to developer_path
    assert @user.reload.auto_claim_tasks

    patch developer_bridge_prefs_path, params: { user: { auto_claim_tasks: "0" } }
    assert_not @user.reload.auto_claim_tasks
  end

  test "bridge_token regenerates and rotates the digest" do
    post developer_bridge_token_path
    first_digest = @user.reload.bridge_token_digest
    post developer_bridge_token_path
    assert_not_equal first_digest, @user.reload.bridge_token_digest
  end

  test "bridge_token requires a signed-in user" do
    sign_out @user
    post developer_bridge_token_path
    assert_redirected_to new_user_session_path
  end
end
