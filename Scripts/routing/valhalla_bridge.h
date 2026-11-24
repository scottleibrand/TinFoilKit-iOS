#ifndef TFK_VALHALLA_BRIDGE_H
#define TFK_VALHALLA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TFKValhalla TFKValhalla;

/* Set the directory of the bundled IANA timezone sources before opening an actor.
 * Returns nonzero on success. Repeated calls with the same directory succeed. */
int tfk_valhalla_set_tzdata(const char *directory, char **error);

/* Pass an app-generated config path. The actor has no HTTP client.
 * Serialize calls to each actor and close it after all calls complete.
 * When provided, the error out-parameter receives an owned message on bridge failure.
 * Free returned strings with tfk_valhalla_string_free. */
TFKValhalla *tfk_valhalla_open(const char *config_path, char **error);
void tfk_valhalla_close(TFKValhalla *actor);
char *tfk_valhalla_route(TFKValhalla *actor, const char *request_json, char **error);
void tfk_valhalla_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
