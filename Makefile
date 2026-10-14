ARCHS = arm64e
TARGET = iphone:clang:latest:16.5
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RootHideFPS
RootHideFPS_FILES = Tweak.xm
RootHideFPS_CFLAGS = -fobjc-arc
RootHideFPS_FRAMEWORKS = UIKit QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
