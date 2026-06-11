module AvatarHelper
  # Renders an avatar for `user` at `size` pixels. Resolution order:
  # uploaded Active Storage attachment (2x variant for HiDPI) →
  # OAuth-cached URL → initials placeholder. External URLs get
  # `referrerpolicy=no-referrer` so the provider can't see which
  # page is requesting the image.
  def avatar_for(user, size: 32, css: "avatar")
    if user.avatar.attached?
      target = size * 2
      variant = user.avatar.variant(resize_to_fill: [ target, target ])
      # Path, not URL: Turbo-broadcast renders have no request, so url_for
      # would mint an absolute src on the renderer's default host.
      image_tag(rails_representation_path(variant, only_path: true),
                width: size, height: size, class: css, alt: "", loading: "lazy")
    elsif user.avatar_url.present?
      image_tag(user.avatar_url,
                width: size, height: size, class: css, alt: "",
                loading: "lazy", referrerpolicy: "no-referrer")
    else
      content_tag(:div, user.initials, class: css, "aria-hidden": "true")
    end
  end
end
