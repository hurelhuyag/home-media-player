// SPDX-License-Identifier: MIT
/*
 * cec2uinput - turn HDMI-CEC remote control presses into key events of a
 * virtual keyboard, so any app (Wayland compositor, browser, player) can be
 * driven with the TV remote.
 *
 * Uses the mainline Linux CEC API (/dev/cecN) directly, no libcec needed.
 * The kernel CEC core already answers GIVE_OSD_NAME, GIVE_PHYSICAL_ADDR,
 * GET_CEC_VERSION and GIVE_DEVICE_VENDOR_ID from the logical address
 * configuration we set, so we only handle what the core passes on to us.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/cec.h>
#include <linux/cec-funcs.h>
#include <linux/uinput.h>

#define UINPUT_NAME "cec2uinput"

/* CEC 1.4 "follower safety timeout": a held key is repeated by the TV every
 * 200-500ms, so if nothing arrives within 550ms the key counts as released. */
#define DEFAULT_RELEASE_TIMEOUT_MS 550

/* The kernel tries to claim a logical address once per physical address. If
 * that fails (bus still settling while TV and receiver wake up) it gives up,
 * so we try again ourselves. */
#define CLAIM_RETRY_MS 10000

/*
 * Keys for what the TV does, so the kiosk can react without a CEC library:
 * pause when the TV switches to another source, resume when it switches back
 * to us, standby when it turns off. The remote's own play/pause button is
 * KEY_PLAYPAUSE, so these never collide with it. Not KEY_SLEEP or KEY_POWER:
 * udev tags us as a "power-switch" and logind would suspend or power off.
 */
#define KEY_SOURCE_LOST KEY_PAUSECD
#define KEY_SOURCE_BACK KEY_PLAYCD
#define KEY_TV_STANDBY KEY_SCREENSAVER

static const char *opt_device = "/dev/cec0";
static const char *opt_osd_name = "YoutubeTV";
static int opt_type = CEC_LOG_ADDR_TYPE_RECORD;
static bool opt_one_touch_play;
static int opt_release_timeout_ms = DEFAULT_RELEASE_TIMEOUT_MS;
static bool opt_verbose;

static volatile sig_atomic_t quit;

static int cec_fd = -1;
static int uinput_fd = -1;

static uint8_t our_la = CEC_LOG_ADDR_INVALID;
static uint16_t our_pa = CEC_PHYS_ADDR_INVALID;
static bool active_source;

static int held_key = -1;
static int64_t held_since_ms;

static int64_t next_claim_ms;

/*
 * CEC UI command -> Linux key code.
 * Chosen so that YouTube TV (Chromium), the Flutter kiosk and mpv understand
 * them without extra configuration; color keys keep the old cec2media F-key
 * layout.
 */
static const uint16_t keymap[256] = {
	[CEC_OP_UI_CMD_SELECT] = KEY_ENTER,
	[CEC_OP_UI_CMD_UP] = KEY_UP,
	[CEC_OP_UI_CMD_DOWN] = KEY_DOWN,
	[CEC_OP_UI_CMD_LEFT] = KEY_LEFT,
	[CEC_OP_UI_CMD_RIGHT] = KEY_RIGHT,
	[CEC_OP_UI_CMD_DEVICE_ROOT_MENU] = KEY_HOME,
	[CEC_OP_UI_CMD_DEVICE_SETUP_MENU] = KEY_MENU,
	[CEC_OP_UI_CMD_CONTENTS_MENU] = KEY_MENU,
	[CEC_OP_UI_CMD_FAVORITE_MENU] = KEY_MENU,
	[CEC_OP_UI_CMD_MEDIA_CONTEXT_SENSITIVE_MENU] = KEY_MENU,
	[CEC_OP_UI_CMD_BACK] = KEY_ESC,
	[CEC_OP_UI_CMD_NUMBER_0_OR_NUMBER_10] = KEY_0,
	[CEC_OP_UI_CMD_NUMBER_1] = KEY_1,
	[CEC_OP_UI_CMD_NUMBER_2] = KEY_2,
	[CEC_OP_UI_CMD_NUMBER_3] = KEY_3,
	[CEC_OP_UI_CMD_NUMBER_4] = KEY_4,
	[CEC_OP_UI_CMD_NUMBER_5] = KEY_5,
	[CEC_OP_UI_CMD_NUMBER_6] = KEY_6,
	[CEC_OP_UI_CMD_NUMBER_7] = KEY_7,
	[CEC_OP_UI_CMD_NUMBER_8] = KEY_8,
	[CEC_OP_UI_CMD_NUMBER_9] = KEY_9,
	[CEC_OP_UI_CMD_DOT] = KEY_DOT,
	[CEC_OP_UI_CMD_ENTER] = KEY_ENTER,
	[CEC_OP_UI_CMD_CLEAR] = KEY_BACKSPACE,
	[CEC_OP_UI_CMD_CHANNEL_UP] = KEY_PAGEUP,
	[CEC_OP_UI_CMD_CHANNEL_DOWN] = KEY_PAGEDOWN,
	[CEC_OP_UI_CMD_PAGE_UP] = KEY_PAGEUP,
	[CEC_OP_UI_CMD_PAGE_DOWN] = KEY_PAGEDOWN,
	/* Letters/F-keys where mpv (the kiosk's player) has a binding: */
	[CEC_OP_UI_CMD_SOUND_SELECT] = KEY_F5,		/* input.conf: cycle audio */
	[CEC_OP_UI_CMD_DISPLAY_INFORMATION] = KEY_I,	/* mpv: show stats */
	[CEC_OP_UI_CMD_HELP] = KEY_HELP,
	[CEC_OP_UI_CMD_VOLUME_UP] = KEY_VOLUMEUP,
	[CEC_OP_UI_CMD_VOLUME_DOWN] = KEY_VOLUMEDOWN,
	[CEC_OP_UI_CMD_MUTE] = KEY_MUTE,
	[CEC_OP_UI_CMD_PLAY] = KEY_PLAYPAUSE,
	[CEC_OP_UI_CMD_STOP] = KEY_STOPCD,
	[CEC_OP_UI_CMD_PAUSE] = KEY_PLAYPAUSE,
	[CEC_OP_UI_CMD_REWIND] = KEY_REWIND,
	[CEC_OP_UI_CMD_FAST_FORWARD] = KEY_FASTFORWARD,
	[CEC_OP_UI_CMD_SKIP_FORWARD] = KEY_NEXTSONG,
	[CEC_OP_UI_CMD_SKIP_BACKWARD] = KEY_PREVIOUSSONG,
	[CEC_OP_UI_CMD_SUB_PICTURE] = KEY_J,		/* mpv: cycle subtitles */
	[CEC_OP_UI_CMD_ELECTRONIC_PROGRAM_GUIDE] = KEY_EPG,
	[CEC_OP_UI_CMD_PLAY_FUNCTION] = KEY_PLAYPAUSE,
	[CEC_OP_UI_CMD_PAUSE_PLAY_FUNCTION] = KEY_PLAYPAUSE,
	[CEC_OP_UI_CMD_STOP_FUNCTION] = KEY_STOPCD,
	[CEC_OP_UI_CMD_MUTE_FUNCTION] = KEY_MUTE,
	/* F1 is the browser help page, so blue goes to F5 like the old app did */
	[CEC_OP_UI_CMD_F1_BLUE] = KEY_F5,
	[CEC_OP_UI_CMD_F2_RED] = KEY_F2,
	[CEC_OP_UI_CMD_F3_GREEN] = KEY_F3,
	[CEC_OP_UI_CMD_F4_YELLOW] = KEY_F4,
	[CEC_OP_UI_CMD_F5] = KEY_F6,
};

static void logf_(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

#define info(...) logf_(__VA_ARGS__)
#define debug(...) do { if (opt_verbose) logf_(__VA_ARGS__); } while (0)

static int64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- uinput ------------------------------------------------------------ */

static void emit(int type, int code, int value)
{
	struct input_event ev = { .type = type, .code = code, .value = value };

	if (write(uinput_fd, &ev, sizeof(ev)) != sizeof(ev))
		info("uinput write failed: %s", strerror(errno));
}

static void key_event(int code, int value)
{
	emit(EV_KEY, code, value);
	emit(EV_SYN, SYN_REPORT, 0);
}

static void key_release(void)
{
	if (held_key < 0)
		return;
	debug("key %d up", held_key);
	key_event(held_key, 0);
	held_key = -1;
}

/* A press and release of its own, for bus events */
static void key_tap(int code)
{
	key_release();
	debug("key %d tap", code);
	key_event(code, 1);
	key_event(code, 0);
}

static void key_press(int code)
{
	held_since_ms = now_ms();
	if (held_key == code)
		return; /* TV repeat while held: the client side handles autorepeat */
	key_release();
	debug("key %d down", code);
	key_event(code, 1);
	held_key = code;
}

static int uinput_open(void)
{
	struct uinput_setup setup = {
		.id = { .bustype = BUS_VIRTUAL, .vendor = 0x1d6b, .product = 0x0cec, .version = 1 },
		.name = UINPUT_NAME,
	};
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);

	if (fd < 0) {
		info("open /dev/uinput: %s", strerror(errno));
		return -1;
	}
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	/* Advertise a full keyboard so udev/libinput classify us as one */
	for (int code = KEY_ESC; code <= KEY_MICMUTE; code++)
		ioctl(fd, UI_SET_KEYBIT, code);
	for (size_t i = 0; i < sizeof(keymap) / sizeof(keymap[0]); i++)
		if (keymap[i])
			ioctl(fd, UI_SET_KEYBIT, keymap[i]);
	ioctl(fd, UI_SET_KEYBIT, KEY_TV_STANDBY);
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		info("create uinput device: %s", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

/* ---- CEC --------------------------------------------------------------- */

static void cec_send(struct cec_msg *msg)
{
	if (our_la == CEC_LOG_ADDR_INVALID)
		return;
	msg->msg[0] = (our_la << 4) | (msg->msg[0] & 0x0f);
	if (ioctl(cec_fd, CEC_TRANSMIT, msg) < 0)
		debug("transmit opcode 0x%02x: %s", msg->msg[1], strerror(errno));
}

static void cec_reply(struct cec_msg *msg, struct cec_msg *orig)
{
	cec_msg_set_reply_to(msg, orig);
	cec_send(msg);
}

static void become_active_source(void)
{
	struct cec_msg msg;

	if (our_pa == CEC_PHYS_ADDR_INVALID)
		return;
	active_source = true;
	cec_msg_init(&msg, our_la, CEC_LOG_ADDR_BROADCAST);
	cec_msg_active_source(&msg, our_pa);
	cec_send(&msg);
}

/* The TV (or a switch) routed its input to us */
static void source_back(void)
{
	bool was_active = active_source;

	become_active_source();
	if (!was_active && active_source) {
		info("TV switched to us");
		key_tap(KEY_SOURCE_BACK);
	}
}

/* The TV switched to its tuner or another device */
static void source_lost(void)
{
	if (!active_source)
		return;
	active_source = false;
	info("TV switched to another source");
	key_tap(KEY_SOURCE_LOST);
}

/*
 * Whether pa is a switch between the TV and us (the AV receiver): the TV
 * routes to it first and the switch then reports which of its inputs is
 * active. The TV itself (0.0.0.0) is excluded, it means its own tuner.
 */
static bool is_our_switch(uint16_t pa)
{
	for (int shift = 12; shift > 0; shift -= 4) {
		uint16_t mask = 0xffff << shift;

		if (!(pa & ~mask) && (pa & mask) && pa == (our_pa & mask) && pa != our_pa)
			return true;
	}
	return false;
}

/* The TV's input now leads to pa (Routing Change / Routing Information) */
static void route_to(uint16_t pa)
{
	if (pa == our_pa)
		source_back();
	else if (!is_our_switch(pa))
		source_lost();
}

static void one_touch_play(void)
{
	struct cec_msg msg;

	info("one touch play: waking TV and switching its input to us");
	cec_msg_init(&msg, our_la, CEC_LOG_ADDR_TV);
	cec_msg_image_view_on(&msg);
	cec_send(&msg);
	become_active_source();
}

static void refresh_addresses(void)
{
	struct cec_log_addrs la = { 0 };
	uint16_t pa = CEC_PHYS_ADDR_INVALID;
	uint8_t old_la = our_la;

	ioctl(cec_fd, CEC_ADAP_G_PHYS_ADDR, &pa);
	ioctl(cec_fd, CEC_ADAP_G_LOG_ADDRS, &la);
	our_pa = pa;
	our_la = la.num_log_addrs && la.log_addr[0] != CEC_LOG_ADDR_INVALID ?
		la.log_addr[0] : CEC_LOG_ADDR_INVALID;

	if (our_pa == CEC_PHYS_ADDR_INVALID)
		info("no physical address (TV off or HDMI unplugged?)");
	else
		info("physical address %x.%x.%x.%x, logical address %d",
		     our_pa >> 12, (our_pa >> 8) & 0xf, (our_pa >> 4) & 0xf, our_pa & 0xf,
		     our_la == CEC_LOG_ADDR_INVALID ? -1 : our_la);

	if (our_la == CEC_LOG_ADDR_INVALID)
		active_source = false;
	else if (old_la == CEC_LOG_ADDR_INVALID && opt_one_touch_play)
		one_touch_play();
}

/* Starts claiming a logical address; the result arrives as a state change event. */
static int claim_address(void)
{
	struct cec_log_addrs la = { 0 };
	uint8_t prim, all;

	next_claim_ms = now_ms() + CLAIM_RETRY_MS;

	switch (opt_type) {
	case CEC_LOG_ADDR_TYPE_PLAYBACK:
		prim = CEC_OP_PRIM_DEVTYPE_PLAYBACK;
		all = CEC_OP_ALL_DEVTYPE_PLAYBACK;
		break;
	case CEC_LOG_ADDR_TYPE_TUNER:
		prim = CEC_OP_PRIM_DEVTYPE_TUNER;
		all = CEC_OP_ALL_DEVTYPE_TUNER;
		break;
	default:
		prim = CEC_OP_PRIM_DEVTYPE_RECORD;
		all = CEC_OP_ALL_DEVTYPE_RECORD;
		break;
	}

	/* Logical addresses can only be set when none are configured */
	ioctl(cec_fd, CEC_ADAP_S_LOG_ADDRS, &la);

	la.cec_version = CEC_OP_CEC_VERSION_1_4;
	la.vendor_id = CEC_VENDOR_ID_NONE;
	snprintf(la.osd_name, sizeof(la.osd_name), "%s", opt_osd_name);
	la.num_log_addrs = 1;
	la.log_addr_type[0] = opt_type;
	la.primary_device_type[0] = prim;
	la.all_device_types[0] = all;
	if (ioctl(cec_fd, CEC_ADAP_S_LOG_ADDRS, &la) < 0) {
		info("CEC_ADAP_S_LOG_ADDRS: %s", strerror(errno));
		return -1;
	}
	info("registered as \"%s\"", la.osd_name);
	return 0;
}

static int cec_configure(void)
{
	struct cec_caps caps;
	__u32 mode = CEC_MODE_INITIATOR | CEC_MODE_FOLLOWER;

	if (ioctl(cec_fd, CEC_ADAP_G_CAPS, &caps) < 0) {
		info("CEC_ADAP_G_CAPS: %s", strerror(errno));
		return -1;
	}
	info("CEC adapter %s (driver %s)", caps.name, caps.driver);
	if (!(caps.capabilities & CEC_CAP_LOG_ADDRS)) {
		info("adapter does not allow configuring logical addresses");
		return -1;
	}
	if (ioctl(cec_fd, CEC_S_MODE, &mode) < 0) {
		info("CEC_S_MODE: %s", strerror(errno));
		return -1;
	}
	return claim_address();
}

static void cec_unconfigure(void)
{
	struct cec_log_addrs la = { 0 };

	if (cec_fd >= 0)
		ioctl(cec_fd, CEC_ADAP_S_LOG_ADDRS, &la);
}

static void handle_message(struct cec_msg *msg)
{
	struct cec_msg reply;
	bool directed = !cec_msg_is_broadcast(msg);
	uint8_t from = cec_msg_initiator(msg);
	uint16_t pa, orig_pa;

	if (msg->len < 2)
		return; /* poll */

	debug("rx %x->%x opcode 0x%02x len %d", from, cec_msg_destination(msg),
	      msg->msg[1], msg->len);

	switch (msg->msg[1]) {
	case CEC_MSG_USER_CONTROL_PRESSED:
		if (msg->len < 3)
			break;
		if (keymap[msg->msg[2]])
			key_press(keymap[msg->msg[2]]);
		else
			info("unmapped CEC UI command 0x%02x", msg->msg[2]);
		break;

	case CEC_MSG_USER_CONTROL_RELEASED:
		key_release();
		break;

	case CEC_MSG_GIVE_DEVICE_POWER_STATUS:
		cec_msg_init(&reply, 0, 0);
		cec_msg_report_power_status(&reply, CEC_OP_POWER_STATUS_ON);
		cec_reply(&reply, msg);
		break;

	case CEC_MSG_MENU_REQUEST:
		/* Several TVs only forward remote keys while our menu is "active" */
		cec_msg_init(&reply, 0, 0);
		cec_msg_menu_status(&reply, CEC_OP_MENU_STATE_ACTIVATED);
		cec_reply(&reply, msg);
		break;

	case CEC_MSG_GIVE_DECK_STATUS:
		cec_msg_init(&reply, 0, 0);
		cec_msg_deck_status(&reply, CEC_OP_DECK_INFO_STOP);
		cec_reply(&reply, msg);
		break;

	case CEC_MSG_REQUEST_ACTIVE_SOURCE:
		if (active_source)
			become_active_source();
		break;

	case CEC_MSG_SET_STREAM_PATH:
		cec_ops_set_stream_path(msg, &pa);
		route_to(pa);
		break;

	case CEC_MSG_ROUTING_CHANGE:
		cec_ops_routing_change(msg, &orig_pa, &pa);
		route_to(pa);
		break;

	case CEC_MSG_ROUTING_INFORMATION:
		cec_ops_routing_information(msg, &pa);
		route_to(pa);
		break;

	case CEC_MSG_ACTIVE_SOURCE:
		cec_ops_active_source(msg, &pa);
		if (pa != our_pa)
			source_lost();
		break;

	case CEC_MSG_STANDBY:
		info("TV standby");
		source_lost();
		key_tap(KEY_TV_STANDBY);
		break;

	case CEC_MSG_FEATURE_ABORT:
	case CEC_MSG_VENDOR_COMMAND:
	case CEC_MSG_VENDOR_COMMAND_WITH_ID:
	case CEC_MSG_VENDOR_REMOTE_BUTTON_DOWN:
	case CEC_MSG_VENDOR_REMOTE_BUTTON_UP:
		break;

	default:
		/* As a follower we must abort directed messages we don't support,
		 * otherwise the TV waits for an answer that never comes. */
		if (directed && !msg->sequence) {
			cec_msg_init(&reply, 0, 0);
			cec_msg_feature_abort(&reply, msg->msg[1],
					      CEC_OP_ABORT_UNRECOGNIZED_OP);
			cec_reply(&reply, msg);
		}
		break;
	}
}

static void handle_event(void)
{
	struct cec_event ev;

	if (ioctl(cec_fd, CEC_DQEVENT, &ev) < 0)
		return;
	switch (ev.event) {
	case CEC_EVENT_STATE_CHANGE:
		refresh_addresses();
		break;
	case CEC_EVENT_LOST_MSGS:
		info("lost %u CEC messages", ev.lost_msgs.lost_msgs);
		break;
	default:
		break;
	}
}

/* ---- main -------------------------------------------------------------- */

static void on_signal(int sig)
{
	(void)sig;
	quit = 1;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"Usage: %s [options]\n"
		"  -d, --device PATH        CEC device (default /dev/cec0)\n"
		"  -n, --name NAME          OSD name shown on the TV, max 14 chars (default YoutubeTV)\n"
		"  -t, --type TYPE          recording | playback | tuner (default recording)\n"
		"  -p, --one-touch-play     wake the TV and switch to our input once registered\n"
		"  -r, --release-timeout MS auto-release a key not repeated within MS (0 = never, default %d)\n"
		"  -v, --verbose            log every CEC message and key event\n",
		argv0, DEFAULT_RELEASE_TIMEOUT_MS);
}

static int parse_args(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "device", required_argument, NULL, 'd' },
		{ "name", required_argument, NULL, 'n' },
		{ "type", required_argument, NULL, 't' },
		{ "one-touch-play", no_argument, NULL, 'p' },
		{ "release-timeout", required_argument, NULL, 'r' },
		{ "verbose", no_argument, NULL, 'v' },
		{ "help", no_argument, NULL, 'h' },
		{ 0 }
	};
	int c;

	while ((c = getopt_long(argc, argv, "d:n:t:pr:vh", longopts, NULL)) != -1) {
		switch (c) {
		case 'd':
			opt_device = optarg;
			break;
		case 'n':
			if (strlen(optarg) > 14) {
				fprintf(stderr, "OSD name is limited to 14 characters\n");
				return -1;
			}
			opt_osd_name = optarg;
			break;
		case 't':
			if (!strcmp(optarg, "playback"))
				opt_type = CEC_LOG_ADDR_TYPE_PLAYBACK;
			else if (!strcmp(optarg, "recording"))
				opt_type = CEC_LOG_ADDR_TYPE_RECORD;
			else if (!strcmp(optarg, "tuner"))
				opt_type = CEC_LOG_ADDR_TYPE_TUNER;
			else {
				fprintf(stderr, "unknown device type %s\n", optarg);
				return -1;
			}
			break;
		case 'p':
			opt_one_touch_play = true;
			break;
		case 'r':
			opt_release_timeout_ms = atoi(optarg);
			break;
		case 'v':
			opt_verbose = true;
			break;
		default:
			usage(argv[0]);
			return -1;
		}
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct sigaction sa = { .sa_handler = on_signal };
	int ret = EXIT_FAILURE;

	if (parse_args(argc, argv) < 0)
		return EXIT_FAILURE;

	setvbuf(stderr, NULL, _IOLBF, 0);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	cec_fd = open(opt_device, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (cec_fd < 0) {
		info("open %s: %s", opt_device, strerror(errno));
		return EXIT_FAILURE;
	}
	uinput_fd = uinput_open();
	if (uinput_fd < 0)
		goto out;
	if (cec_configure() < 0)
		goto out;
	refresh_addresses();

	while (!quit) {
		struct pollfd pfd = { .fd = cec_fd, .events = POLLIN | POLLPRI };
		int timeout = -1;

		if (held_key >= 0 && opt_release_timeout_ms > 0) {
			timeout = (int)(held_since_ms + opt_release_timeout_ms - now_ms());
			if (timeout <= 0) {
				key_release();
				continue;
			}
		}
		if (our_la == CEC_LOG_ADDR_INVALID && our_pa != CEC_PHYS_ADDR_INVALID) {
			int wait = (int)(next_claim_ms - now_ms());

			if (wait <= 0) {
				info("no logical address yet, claiming again");
				claim_address();
				continue;
			}
			if (timeout < 0 || wait < timeout)
				timeout = wait;
		}

		if (poll(&pfd, 1, timeout) < 0) {
			if (errno == EINTR)
				continue;
			info("poll: %s", strerror(errno));
			goto out;
		}
		if (pfd.revents & (POLLERR | POLLHUP)) {
			info("CEC device went away");
			goto out;
		}
		if (pfd.revents & POLLPRI)
			handle_event();
		if (pfd.revents & POLLIN) {
			struct cec_msg msg = { 0 };

			while (ioctl(cec_fd, CEC_RECEIVE, &msg) == 0) {
				handle_message(&msg);
				memset(&msg, 0, sizeof(msg));
			}
		}
	}
	ret = EXIT_SUCCESS;

out:
	if (uinput_fd >= 0) {
		key_release();
		ioctl(uinput_fd, UI_DEV_DESTROY);
		close(uinput_fd);
	}
	cec_unconfigure();
	close(cec_fd);
	return ret;
}
