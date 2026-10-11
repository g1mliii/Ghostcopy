#include <glib.h>
#include <wayland-server.h>
#include <unistd.h>

#include <cassert>
#include <cstdio>
#include <functional>

#include "clipboard_monitor.h"
#include "wlr-data-control-server.h"

// A real local Wayland connection, with no compositor or clipboard contents.
// Any payload request is a test failure. Exercises the protocol rather than
// mocking the counter that the production client is supposed to maintain.
namespace {
struct Server {
  wl_display* display = wl_display_create();
  wl_resource* device = nullptr;
  int destroyed_offers = 0;
  int received_payloads = 0;
  int writes = 0;

  static void Destroy(wl_client*, wl_resource* resource) { wl_resource_destroy(resource); }
  static void SetSelection(wl_client*, wl_resource* resource, wl_resource*) {
    ++static_cast<Server*>(wl_resource_get_user_data(resource))->writes;
  }
  static void Receive(wl_client*, wl_resource* resource, const char*, int32_t fd) {
    ++static_cast<Server*>(wl_resource_get_user_data(resource))->received_payloads;
    close(fd);
  }
  static void GetDevice(wl_client* client, wl_resource* manager, uint32_t id, wl_resource*) {
    auto* self = static_cast<Server*>(wl_resource_get_user_data(manager));
    self->device = wl_resource_create(client, &zwlr_data_control_device_v1_interface, 2, id);
    static const struct zwlr_data_control_device_v1_interface impl = {
        SetSelection, Destroy, SetSelection};
    wl_resource_set_implementation(self->device, &impl, self, +[](wl_resource* resource) {
      static_cast<Server*>(wl_resource_get_user_data(resource))->device = nullptr;
    });
    zwlr_data_control_device_v1_send_selection(self->device, nullptr);
    zwlr_data_control_device_v1_send_primary_selection(self->device, nullptr);
  }

  explicit Server(bool supported = true) {
    const char* socket = wl_display_add_socket_auto(display);
    assert(socket);
    g_setenv("WAYLAND_DISPLAY", socket, TRUE);
    wl_global_create(display, &wl_seat_interface, 1, this,
        +[](wl_client* client, void*, uint32_t, uint32_t id) {
          auto* seat = wl_resource_create(client, &wl_seat_interface, 1, id);
          wl_resource_set_implementation(seat, nullptr, nullptr, nullptr);
          wl_seat_send_capabilities(seat, 0);
        });
    if (supported) {
      wl_global_create(display, &zwlr_data_control_manager_v1_interface, 2, this,
          +[](wl_client* client, void* data, uint32_t version, uint32_t id) {
            auto* manager = wl_resource_create(client, &zwlr_data_control_manager_v1_interface, version, id);
            static const struct zwlr_data_control_manager_v1_interface impl = {
                +[](wl_client*, wl_resource*, uint32_t) { assert(false && "must not create a data source"); },
                GetDevice, Destroy};
            wl_resource_set_implementation(manager, &impl, data, nullptr);
          });
    }
  }

  void Offer(bool primary = false) {
    assert(device);
    auto* offer = wl_resource_create(wl_resource_get_client(device), &zwlr_data_control_offer_v1_interface, 1, 0);
    static const struct zwlr_data_control_offer_v1_interface impl = {Receive, Destroy};
    wl_resource_set_implementation(offer, &impl, this, +[](wl_resource* resource) {
      ++static_cast<Server*>(wl_resource_get_user_data(resource))->destroyed_offers;
    });
    zwlr_data_control_device_v1_send_data_offer(device, offer);
    zwlr_data_control_offer_v1_send_offer(offer, "text/plain");
    zwlr_data_control_offer_v1_send_offer(offer, "image/png");
    if (primary) zwlr_data_control_device_v1_send_primary_selection(device, offer);
    else zwlr_data_control_device_v1_send_selection(device, offer);
    wl_display_flush_clients(display);
  }

  void Pump() {
    wl_event_loop_dispatch(wl_display_get_event_loop(display), 0);
    wl_display_flush_clients(display);
    while (g_main_context_iteration(nullptr, FALSE)) {}
  }

  void Until(const std::function<bool()>& condition) {
    const auto deadline = g_get_monotonic_time() + 2 * G_TIME_SPAN_SECOND;
    while (!condition() && g_get_monotonic_time() < deadline) {
      Pump();
      g_usleep(1000);
    }
    assert(condition());
  }

  ~Server() {
    assert(received_payloads == 0);
    assert(writes == 0);
    wl_display_destroy_clients(display);
    wl_display_destroy(display);
  }
};
}  // namespace

int main() {
  g_autofree char* runtime = g_dir_make_tmp("ghostcopy-wayland-test-XXXXXX", nullptr);
  assert(runtime);
  g_setenv("XDG_RUNTIME_DIR", runtime, TRUE);
  {
    Server server;
    int changes = 0;
    ClipboardMonitor monitor([&]() { ++changes; });
    int64_t count = -1;
    assert(!monitor.Read(&count));  // Connecting must not masquerade as unchanged.
    server.Until([&]() { return monitor.Read(&count); });
    assert(count == 1 && changes == 1);
    server.Offer();
    // Query before giving GLib a turn: pending local copies must already
    // prevent Smart Receive from overwriting them.
    assert(monitor.Read(&count) && count == 2);
    assert(changes == 2);
    server.Offer(true);
    server.Offer(true);
    server.Until([&]() { return server.destroyed_offers == 1; });
    assert(monitor.Read(&count) && count == 2 && changes == 2);
    server.Offer();
    server.Until([&]() { return server.destroyed_offers == 2; });
    assert(monitor.Read(&count) && count == 3);
    zwlr_data_control_device_v1_send_selection(server.device, nullptr);
    server.Until([&]() { return monitor.Read(&count) && count == 4; });
    zwlr_data_control_device_v1_send_finished(server.device);
    server.Until([&]() { return !monitor.Read(&count); });
  }
  {
    Server server;
    ClipboardMonitor monitor([]() {});
    int64_t count = 0;
    server.Until([&]() { return monitor.Read(&count); });
    wl_display_destroy_clients(server.display);
    server.Until([&]() { return !monitor.Read(&count); });
  }
  {
    Server server(false);
    ClipboardMonitor monitor([]() {});
    int64_t count = 0;
    assert(!monitor.Read(&count));
    for (int i = 0; i < 20; ++i) server.Pump();
    assert(!monitor.Read(&count));  // No data-control: caller must keep reading.
  }
  assert(rmdir(runtime) == 0);
  std::puts("Wayland monitor passed: events, primary isolation, offer cleanup, unavailable/disconnect, no payload reads or writes.");
}
