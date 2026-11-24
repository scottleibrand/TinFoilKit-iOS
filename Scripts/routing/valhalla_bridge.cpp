#include "valhalla_bridge.h"

#include "include/main.h"
#include "date/tz.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <mutex>
#include <string>

namespace {

std::mutex timezone_mutex;
std::string timezone_directory;

void set_error(char **error, const char *message) {
    if (error) {
        *error = ::strdup(message);
    }
}

}

int tfk_valhalla_set_tzdata(const char *directory, char **error) {
    if (error) {
        *error = nullptr;
    }
    if (!directory || !directory[0]) {
        set_error(error, "Missing bundled timezone database.");
        return 0;
    }
    try {
        const std::lock_guard lock(timezone_mutex);
        if (!timezone_directory.empty()) {
            if (timezone_directory == directory) {
                return 1;
            }
            set_error(error, "The timezone database directory is already configured.");
            return 0;
        }
        const std::string path(directory);
        std::string version;
        std::ifstream input(path + "/version");
        if (!(input >> version) || version != "2025b") {
            set_error(error, "The bundled timezone database must be IANA 2025b.");
            return 0;
        }
        date::set_install(path);
        if (date::get_tzdb().version != version) {
            set_error(error, "The route engine loaded an unexpected timezone database.");
            return 0;
        }
        timezone_directory = path;
        return 1;
    } catch (const std::exception &failure) {
        set_error(error, failure.what());
    } catch (...) {
        set_error(error, "Could not load the bundled timezone database.");
    }
    return 0;
}

TFKValhalla *tfk_valhalla_open(const char *config_path, char **error) {
    if (error) {
        *error = nullptr;
    }
    if (!config_path || !config_path[0]) {
        set_error(error, "Missing route configuration.");
        return nullptr;
    }
    try {
        {
            const std::lock_guard lock(timezone_mutex);
            if (timezone_directory.empty()) {
                set_error(error, "Configure the timezone database before opening the route engine.");
                return nullptr;
            }
        }
        return static_cast<TFKValhalla *>(create_valhalla_actor(config_path, nullptr));
    } catch (const std::exception &failure) {
        set_error(error, failure.what());
    } catch (...) {
        set_error(error, "Could not start the route engine.");
    }
    return nullptr;
}

void tfk_valhalla_close(TFKValhalla *actor) {
    if (actor) {
        delete_valhalla_actor(actor);
    }
}

char *tfk_valhalla_route(TFKValhalla *actor, const char *request_json, char **error) {
    if (error) {
        *error = nullptr;
    }
    if (!actor || !request_json) {
        set_error(error, "Missing route engine or request.");
        return nullptr;
    }
    try {
        const std::string response = route(request_json, actor);
        if (auto *copy = ::strdup(response.c_str())) {
            return copy;
        }
        set_error(error, "Could not allocate route response.");
    } catch (const std::exception &failure) {
        set_error(error, failure.what());
    } catch (...) {
        set_error(error, "The route engine failed.");
    }
    return nullptr;
}

void tfk_valhalla_string_free(char *string) {
    std::free(string);
}
