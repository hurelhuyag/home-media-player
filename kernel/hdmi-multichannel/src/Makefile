# Out-of-tree builds of two Amlogic ASoC modules with LibreELEC's fixes for
# multichannel HDMI audio (see patches/):
#  0147: g12a-tohdmitx no longer limits 6/8 channel streams to stereo
#  0129: the HDMI codec's ELD, channel map and IEC958 controls show up on the
#        PCM devices apps open, so players reorder channels correctly
obj-m := snd-soc-meson-g12a-tohdmitx.o snd-soc-meson-card-utils.o
snd-soc-meson-g12a-tohdmitx-y := g12a-tohdmitx.o
snd-soc-meson-card-utils-y := meson-card-utils.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
