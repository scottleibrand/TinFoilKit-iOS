#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct TFKArchive TFKArchive;
typedef struct TFKResource TFKResource;
typedef struct TFKEntryMetadata TFKEntryMetadata;
typedef struct TFKTitleMatches TFKTitleMatches;

/* Callers supply valid file and path strings and release owned handles. An
 * error output, if provided, must point to an empty slot. Read operations
 * may run simultaneously while the archive remains open. */
TFKArchive *tfk_archive_open(const char *file, char **error);
void tfk_archive_close(TFKArchive *archive);
uint32_t tfk_archive_entry_count(const TFKArchive *archive);
/* Returns null on success or an owned error string. */
char *tfk_archive_verify_checksum(const TFKArchive *archive);
char *tfk_archive_title(const TFKArchive *archive);
TFKResource *tfk_archive_main(const TFKArchive *archive, char **error);
TFKResource *tfk_archive_resource(const TFKArchive *archive, const char *path, char **error);

/* Returns a non-redirect HTML article at a URL-table index. A null result
 * with no error means the entry is outside the searchable article set. */
TFKResource *tfk_archive_article(const TFKArchive *archive, uint32_t index, char **error);

/* The result owns up to 30 title matches. Entry metadata is borrowed until
 * the result is closed. Entry lookup returns null after the final match. */
TFKTitleMatches *tfk_archive_title_prefix(const TFKArchive *archive, const char *prefix, char **error);
const TFKEntryMetadata *tfk_title_matches_entry(const TFKTitleMatches *matches, size_t index);
void tfk_title_matches_close(TFKTitleMatches *matches);

/* Returns a non-redirect PDF entry without reading the PDF bytes. A null
 * result with no error means the entry is not a PDF. */
TFKEntryMetadata *tfk_archive_pdf_entry(const TFKArchive *archive, uint32_t index, char **error);
const char *tfk_entry_metadata_path(const TFKEntryMetadata *entry);
const char *tfk_entry_metadata_title(const TFKEntryMetadata *entry);
void tfk_entry_metadata_close(TFKEntryMetadata *entry);

/* Resource strings and bytes are borrowed until the resource is closed. */
const char *tfk_resource_path(const TFKResource *resource);
const char *tfk_resource_title(const TFKResource *resource);
const char *tfk_resource_mime(const TFKResource *resource);
const uint8_t *tfk_resource_bytes(const TFKResource *resource, size_t *length);
void tfk_resource_close(TFKResource *resource);
void tfk_string_free(char *value);
