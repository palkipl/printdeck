#!/usr/bin/env python3
"""
PrintDeck - native Raspberry Pi app (GTK + WebKit, no Chromium)

Keys:  Esc = leave full screen   F11 = toggle full screen
       F5  = reload              Ctrl+Q = quit
"""
import os
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

GLib.set_prgname("printdeck")   # taskbar/menu icon matching (StartupWMClass=printdeck)

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADING = "file://" + os.path.join(DIR, "static", "loading.html")
ICON = os.path.join(DIR, "branding", "icon.png")
BG = Gdk.RGBA()
BG.parse("#07090d")


class PrintDeck(Gtk.Application):
    def __init__(self, fullscreen):
        super().__init__(application_id="com.printdeck.app")
        self.start_fullscreen = fullscreen
        self.win = None

    def do_activate(self):
        if self.win:                      # already running -> just bring it forward
            self.win.present()
            return
        GLib.set_application_name("PrintDeck")
        win = Gtk.ApplicationWindow(application=self, title="PrintDeck")
        win.set_default_size(1024, 600)
        if os.path.exists(ICON):
            win.set_icon_from_file(ICON)
        css = Gtk.CssProvider()
        css.load_from_data(b"window { background-color: #07090d; }")
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        s = WebKit2.Settings()
        s.set_enable_mediasource(True)
        s.set_media_playback_requires_user_gesture(False)
        s.set_allow_file_access_from_file_urls(True)
        s.set_allow_universal_access_from_file_urls(True)
        s.set_enable_developer_extras(False)
        s.set_enable_back_forward_navigation_gestures(False)
        for prop in ("enable-webrtc", "enable-media-stream"):
            try:
                s.set_property(prop, True)
            except TypeError:
                pass  # older WebKit without WebRTC

        view = WebKit2.WebView()
        view.set_settings(s)
        view.set_background_color(BG)
        view.connect("web-process-terminated", lambda v, r: GLib.timeout_add_seconds(2, self.reload))
        view.connect("context-menu", lambda *a: True)          # no right-click menu
        view.load_uri(LOADING)

        win.add(view)
        win.connect("key-press-event", self.on_key)
        win.show_all()
        if self.start_fullscreen:
            win.fullscreen()
        self.win, self.view, self.is_full = win, view, self.start_fullscreen
        win.connect("window-state-event", self.on_state)

    def on_state(self, win, event):
        self.is_full = bool(event.new_window_state & Gdk.WindowState.FULLSCREEN)

    def reload(self):
        self.view.load_uri(LOADING)
        return False

    def on_key(self, win, ev):
        ctrl = ev.state & Gdk.ModifierType.CONTROL_MASK
        if ev.keyval == Gdk.KEY_Escape and self.is_full:
            win.unfullscreen()
        elif ev.keyval == Gdk.KEY_F11:
            win.unfullscreen() if self.is_full else win.fullscreen()
        elif ev.keyval == Gdk.KEY_F5:
            self.reload()
        elif ctrl and ev.keyval in (Gdk.KEY_q, Gdk.KEY_Q):
            self.quit()
        else:
            return False
        return True


if __name__ == "__main__":
    full = "--windowed" not in sys.argv
    sys.exit(PrintDeck(full).run([sys.argv[0]]))
