#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct TFKArchive TFKArchive;
typedef struct TFKResource TFKResource;

/* Callers supply valid file and path strings and release owned handles. An
 * error output, if provided, must point to an empty slot. Read operations
 * may run simultaneously while the archive remains open. */
TFKArchive *tfk_archive_open(const char *file, char **error);
void tfk_archive_close(TFKArchive *archive);
uint32_t tfk_archive_entry_count(const TFKArchive *archive);
char *tfk_archive_title(const TFKArchive *archive);
TFKResource *tfk_archive_main(const TFKArchive *archive, char **error);
TFKResource *tfk_archive_resource(const TFKArchive *archive, const char *path, char **error);

/* Returns a non-redirect HTML article at a URL-table index. A null result
 * with no error means the entry is outside the searchable article set. */
TFKResource *tfk_archive_article(const TFKArchive *archive, uint32_t index, char **error);

/* Resource strings and bytes are borrowed until the resource is closed. */
const char *tfk_resource_path(const TFKResource *resource);
const char *tfk_resource_title(const TFKResource *resource);
const char *tfk_resource_mime(const TFKResource *resource);
const uint8_t *tfk_resource_bytes(const TFKResource *resource, size_t *length);
void tfk_resource_close(TFKResource *resource);
void tfk_string_free(char *value);
