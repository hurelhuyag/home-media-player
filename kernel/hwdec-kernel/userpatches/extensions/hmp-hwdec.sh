# home-media-player: LibreELEC's stateless video decoder (amvdec) replaces the
# staging meson-vdec driver, which its patch removes.
function custom_kernel_config__hmp_hwdec() {
	opts_m+=("VIDEO_MESON_AMVDEC")
	opts_n+=("VIDEO_MESON_VDEC")
	kernel_config_modifying_hashes+=("VIDEO_MESON_AMVDEC=m" "VIDEO_MESON_VDEC=n")
}
