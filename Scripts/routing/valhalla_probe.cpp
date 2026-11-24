#include "valhalla_bridge.h"

#include <cstdio>
#include <memory>

int main(int argc, char **argv) {
    if (argc != 4) {
        std::fputs("Usage: valhalla-probe TZDATA CONFIG_JSON REQUEST_JSON\n", stderr);
        return 2;
    }

    char *error = nullptr;
    if (!tfk_valhalla_set_tzdata(argv[1], &error)) {
        std::fprintf(stderr, "%s\n", error ? error : "Could not load timezone data.");
        tfk_valhalla_string_free(error);
        return 1;
    }
    const std::unique_ptr<TFKValhalla, decltype(&tfk_valhalla_close)> actor(
        tfk_valhalla_open(argv[2], &error), tfk_valhalla_close);
    if (!actor) {
        std::fprintf(stderr, "%s\n", error ? error : "Could not start routing.");
        tfk_valhalla_string_free(error);
        return 1;
    }

    const std::unique_ptr<char, decltype(&tfk_valhalla_string_free)> response(
        tfk_valhalla_route(actor.get(), argv[3], &error), tfk_valhalla_string_free);
    if (!response) {
        std::fprintf(stderr, "%s\n", error ? error : "Could not route.");
        tfk_valhalla_string_free(error);
        return 1;
    }
    std::puts(response.get());
}
