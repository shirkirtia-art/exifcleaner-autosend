/**
 * libcleanupload - Zero-Duplicate On-The-Fly Metadata Sanitizer Interceptor
 *
 * Intercepts file chooser dialogs and direct file opens in web browsers and
 * messaging clients (Discord, Telegram, Chrome, Firefox, etc.) to transparently
 * strip metadata into an ephemeral RAM location, serve the sanitized bytes
 * to the uploading process, and trigger an automatic self-destruct once uploaded.
 *
 * Copyright (c) 2026. Released under the MIT License.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>

/* Forward declarations for GLib / GTK data structures */
typedef struct _GSList GSList;
struct _GSList {
    void *data;
    GSList *next;
};

typedef void GFile;
typedef void GtkFileChooser;

typedef enum {
    GTK_ACTION_OPEN,
    GTK_ACTION_SAVE,
    GTK_ACTION_SELECT_FOLDER,
    GTK_ACTION_CREATE_FOLDER
} ActionType;

/* Function pointer prototypes */
typedef void *(*dlsym_fn_t)(void *, const char *);
typedef char *(*gtk_get_filename_fn)(GtkFileChooser *);
typedef GSList *(*gtk_get_filenames_fn)(GtkFileChooser *);
typedef GFile *(*gtk_get_file_fn)(GtkFileChooser *);
typedef GSList *(*gtk_get_files_fn)(GtkFileChooser *);
typedef char *(*gtk_get_uri_fn)(GtkFileChooser *);
typedef GSList *(*gtk_get_uris_fn)(GtkFileChooser *);
typedef int (*gtk_get_action_fn)(GtkFileChooser *);

typedef void (*g_free_fn)(void *);
typedef char *(*g_strdup_fn)(const char *);
typedef char *(*g_file_get_path_fn)(GFile *);
typedef GFile *(*g_file_new_for_path_fn)(const char *);
typedef void (*g_object_unref_fn)(void *);
typedef char *(*g_filename_to_uri_fn)(const char *, const char *, void **);
typedef char *(*g_filename_from_uri_fn)(const char *, char **, void **);

typedef int (*open_fn_t)(const char *, int, ...);
typedef int (*openat_fn_t)(int, const char *, int, ...);

/* Original symbol storage */
static dlsym_fn_t real_dlsym = NULL;
static gtk_get_filename_fn orig_get_filename = NULL;
static gtk_get_filenames_fn orig_get_filenames = NULL;
static gtk_get_file_fn orig_get_file = NULL;
static gtk_get_files_fn orig_get_files = NULL;
static gtk_get_uri_fn orig_get_uri = NULL;
static gtk_get_uris_fn orig_get_uris = NULL;
static gtk_get_action_fn orig_get_action = NULL;

static open_fn_t orig_open = NULL;
static open_fn_t orig_open64 = NULL;
static open_fn_t orig_open_2 = NULL;
static openat_fn_t orig_openat = NULL;
static openat_fn_t orig_openat64 = NULL;
static openat_fn_t orig_openat_2 = NULL;

static g_free_fn real_g_free = NULL;
static g_strdup_fn real_g_strdup = NULL;
static g_file_get_path_fn real_g_file_get_path = NULL;
static g_file_new_for_path_fn real_g_file_new_for_path = NULL;
static g_object_unref_fn real_g_object_unref = NULL;
static g_filename_to_uri_fn real_g_filename_to_uri = NULL;
static g_filename_from_uri_fn real_g_filename_from_uri = NULL;

/* Thread-local re-entrancy prevention */
static __thread int in_hook = 0;

/* Cleaned file cache to handle multi-stage uploads (preview then upload) */
struct CacheEntry {
    char orig[512];
    char clean[1024];
    time_t created;
};
#define CACHE_MAX 32
static struct CacheEntry s_cache[CACHE_MAX];
static int s_cache_idx = 0;
static pthread_mutex_t s_cache_lock = PTHREAD_MUTEX_INITIALIZER;

static void init_real_dlsym(void) {
    if (real_dlsym) return;
    static const char *const versions[] = {
        "GLIBC_2.34",
        "GLIBC_2.2.5",
        "GLIBC_2.17",
        "GLIBC_2.4",
        "GLIBC_2.0",
        "GLIBC_2.27",
        NULL
    };
    for (int i = 0; versions[i] != NULL; i++) {
        real_dlsym = (dlsym_fn_t)dlvsym(RTLD_NEXT, "dlsym", versions[i]);
        if (real_dlsym) break;
    }
    if (!real_dlsym) {
        real_dlsym = (dlsym_fn_t)dlvsym(RTLD_DEFAULT, "dlsym", "GLIBC_2.34");
    }
}

static void *resolve_next(const char *name) {
    init_real_dlsym();
    if (real_dlsym) {
        return real_dlsym(RTLD_NEXT, name);
    }
    return NULL;
}

static void *resolve_default(const char *name) {
    init_real_dlsym();
    if (real_dlsym) {
        return real_dlsym(RTLD_DEFAULT, name);
    }
    return NULL;
}

static void init_glib_symbols(void) {
    if (!real_g_free) real_g_free = (g_free_fn)resolve_default("g_free");
    if (!real_g_strdup) real_g_strdup = (g_strdup_fn)resolve_default("g_strdup");
    if (!real_g_file_get_path) real_g_file_get_path = (g_file_get_path_fn)resolve_default("g_file_get_path");
    if (!real_g_file_new_for_path) real_g_file_new_for_path = (g_file_new_for_path_fn)resolve_default("g_file_new_for_path");
    if (!real_g_object_unref) real_g_object_unref = (g_object_unref_fn)resolve_default("g_object_unref");
    if (!real_g_filename_to_uri) real_g_filename_to_uri = (g_filename_to_uri_fn)resolve_default("g_filename_to_uri");
    if (!real_g_filename_from_uri) real_g_filename_from_uri = (g_filename_from_uri_fn)resolve_default("g_filename_from_uri");
}

static void safe_g_free(void *ptr) {
    init_glib_symbols();
    if (real_g_free) real_g_free(ptr);
    else free(ptr);
}

static char *safe_g_strdup(const char *str) {
    init_glib_symbols();
    if (real_g_strdup) return real_g_strdup(str);
    return strdup(str);
}

/**
 * Detect if the calling process is a web browser, messaging app, or portal daemon.
 */
static int is_sharing_app(void) {
    extern char *program_invocation_short_name;
    if (!program_invocation_short_name) return 0;
    const char *p = program_invocation_short_name;
    if (strcasestr(p, "discord") ||
        strcasestr(p, "chrome") ||
        strcasestr(p, "chromium") ||
        strcasestr(p, "firefox") ||
        strcasestr(p, "telegram") ||
        strcasestr(p, "slack") ||
        strcasestr(p, "brave") ||
        strcasestr(p, "opera") ||
        strcasestr(p, "edge") ||
        strcasestr(p, "thunderbird") ||
        strcasestr(p, "xdg-desktop-por")) {
        return 1;
    }
    return 0;
}

/**
 * Check if the target file should be cleaned.
 */
static int is_cleanable_file(const char *path) {
    if (!path || *path == '\0') return 0;
    if (strncmp(path, "/dev/shm/.clean_send/", 21) == 0) return 0;
    if (strncmp(path, "/tmp/.clean_send/", 17) == 0) return 0;

    /* Only intercept user file paths */
    if (strncmp(path, "/home/", 6) != 0) return 0;

    /* Exclude application configuration, internal caches, and crash dumps */
    if (strstr(path, "/.config/") != NULL ||
        strstr(path, "/.cache/") != NULL ||
        strstr(path, "/.local/share/discord/") != NULL ||
        strstr(path, "/.local/share/google-chrome/") != NULL ||
        strstr(path, "/.mozilla/") != NULL ||
        strstr(path, "/Crashpad/") != NULL ||
        strstr(path, "/Crash Reports/") != NULL ||
        strstr(path, "/modules/") != NULL) {
        return 0;
    }

    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
        return 0;
    }

    const char *dot = strrchr(path, '.');
    if (!dot) return 0;

    static const char *supported_exts[] = {
        /* Images */
        ".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".avif",
        ".tiff", ".tif", ".gif", ".bmp", ".svg",
        /* Documents */
        ".pdf", ".docx", ".xlsx", ".pptx", ".doc", ".xls", ".ppt",
        ".odt", ".ods", ".odp",
        /* Audio/Video */
        ".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm",
        ".mp3", ".wav", ".ogg", ".flac",
        NULL
    };

    for (int i = 0; supported_exts[i] != NULL; i++) {
        if (strcasecmp(dot, supported_exts[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/**
 * Fast in-kernel file copy using standard POSIX read/write.
 */
static int copy_file_data(const char *src, const char *dst) {
    int sfd = open(src, O_RDONLY);
    if (sfd < 0) return -1;

    int dfd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (dfd < 0) {
        close(sfd);
        return -1;
    }

    char buf[65536];
    ssize_t r;
    while ((r = read(sfd, buf, sizeof(buf))) > 0) {
        char *p = buf;
        ssize_t w;
        while (r > 0) {
            w = write(dfd, p, (size_t)r);
            if (w < 0) {
                if (errno == EINTR) continue;
                close(sfd);
                close(dfd);
                return -1;
            }
            r -= w;
            p += w;
        }
    }

    close(sfd);
    close(dfd);
    return 0;
}

/**
 * Create a cleaned ephemeral copy in /dev/shm/.clean_send/ and launch auto-purge.
 */
char *prepare_cleaned_file(const char *orig_path) {
    if (!is_cleanable_file(orig_path)) {
        return (char *)orig_path;
    }

    time_t now = time(NULL);

    /* Check cache for recently cleaned copy */
    pthread_mutex_lock(&s_cache_lock);
    for (int i = 0; i < CACHE_MAX; i++) {
        if (s_cache[i].orig[0] != '\0' &&
            strcmp(s_cache[i].orig, orig_path) == 0 &&
            (now - s_cache[i].created) < 60) {
            if (access(s_cache[i].clean, R_OK) == 0) {
                char *res = safe_g_strdup(s_cache[i].clean);
                pthread_mutex_unlock(&s_cache_lock);
                return res;
            }
        }
    }
    pthread_mutex_unlock(&s_cache_lock);

    const char *bname = strrchr(orig_path, '/');
    bname = bname ? (bname + 1) : orig_path;

    /* Base ephemeral directory with sticky world-writable permissions */
    mkdir("/dev/shm/.clean_send", 01777);
    chmod("/dev/shm/.clean_send", 01777);

    char session_dir[512];
    snprintf(session_dir, sizeof(session_dir), "/dev/shm/.clean_send/s_%d_%ld_%d",
             getpid(), (long)now, rand() % 100000);

    if (mkdir(session_dir, 0700) != 0) {
        return (char *)orig_path;
    }

    char clean_path[1024];
    snprintf(clean_path, sizeof(clean_path), "%s/%s", session_dir, bname);

    if (copy_file_data(orig_path, clean_path) != 0) {
        rmdir(session_dir);
        return (char *)orig_path;
    }

    /* Clean metadata synchronously */
    pid_t cpid = fork();
    if (cpid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        execl("/usr/local/bin/clean-for-send", "clean-for-send", clean_path, (char *)NULL);
        _exit(1);
    } else if (cpid > 0) {
        int status;
        waitpid(cpid, &status, 0);
    } else {
        /* Fork failed (e.g. seccomp sandbox restriction) - fall back safely */
        rmdir(session_dir);
        return (char *)orig_path;
    }

    /* Update cache */
    pthread_mutex_lock(&s_cache_lock);
    int slot = s_cache_idx % CACHE_MAX;
    snprintf(s_cache[slot].orig, sizeof(s_cache[slot].orig), "%s", orig_path);
    snprintf(s_cache[slot].clean, sizeof(s_cache[slot].clean), "%s", clean_path);
    s_cache[slot].created = now;
    s_cache_idx++;
    pthread_mutex_unlock(&s_cache_lock);

    /* Background daemon watcher */
    pid_t wpid = fork();
    if (wpid == 0) {
        if (fork() == 0) {
            setsid();
            int devnull = open("/dev/null", O_RDWR);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                close(devnull);
            }
            execl("/usr/local/bin/clean-auto-purge", "clean-auto-purge", session_dir, bname, "600", (char *)NULL);
            _exit(0);
        }
        _exit(0);
    } else if (wpid > 0) {
        waitpid(wpid, NULL, 0);
    }

    return safe_g_strdup(clean_path);
}

/* ========================================================================= */
/* Syscall Redirection: open / openat                                       */
/* Intercepts Drag & Drop and direct opens in Discord, Chrome, Telegram, etc */
/* ========================================================================= */

static const char *get_redirect_path(const char *path, int flags) {
    if (in_hook) return path;
    if ((flags & O_ACCMODE) != O_RDONLY) return path;
    if (flags & (O_CREAT | O_TRUNC | O_WRONLY | O_RDWR)) return path;

    if (!is_sharing_app()) return path;
    if (!is_cleanable_file(path)) return path;

    in_hook = 1;
    char *cleaned = prepare_cleaned_file(path);
    in_hook = 0;

    return cleaned ? cleaned : path;
}

int open(const char *pathname, int flags, ...) {
    if (!orig_open) orig_open = (open_fn_t)resolve_next("open");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    const char *target = get_redirect_path(pathname, flags);
    int res = orig_open(target, flags, mode);
    if (target != pathname) safe_g_free((void *)target);
    return res;
}

int open64(const char *pathname, int flags, ...) {
    if (!orig_open64) orig_open64 = (open_fn_t)resolve_next("open64");
    if (!orig_open64) orig_open64 = orig_open;

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    const char *target = get_redirect_path(pathname, flags);
    int res = orig_open64 ? orig_open64(target, flags, mode) : open(target, flags, mode);
    if (target != pathname) safe_g_free((void *)target);
    return res;
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat) orig_openat = (openat_fn_t)resolve_next("openat");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    const char *target = get_redirect_path(pathname, flags);
    int res;
    if (target != pathname) {
        res = orig_openat(AT_FDCWD, target, flags, mode);
        safe_g_free((void *)target);
    } else {
        res = orig_openat(dirfd, pathname, flags, mode);
    }
    return res;
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat64) orig_openat64 = (openat_fn_t)resolve_next("openat64");
    if (!orig_openat64) orig_openat64 = orig_openat;

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }

    const char *target = get_redirect_path(pathname, flags);
    int res;
    if (target != pathname) {
        res = orig_openat64 ? orig_openat64(AT_FDCWD, target, flags, mode) : openat(AT_FDCWD, target, flags, mode);
        safe_g_free((void *)target);
    } else {
        res = orig_openat64 ? orig_openat64(dirfd, pathname, flags, mode) : openat(dirfd, pathname, flags, mode);
    }
    return res;
}

int __open_2(const char *pathname, int flags) {
    if (!orig_open_2) orig_open_2 = (open_fn_t)resolve_next("__open_2");
    if (!orig_open_2) return open(pathname, flags);

    const char *target = get_redirect_path(pathname, flags);
    int res = orig_open_2(target, flags);
    if (target != pathname) safe_g_free((void *)target);
    return res;
}

int __openat_2(int dirfd, const char *pathname, int flags) {
    if (!orig_openat_2) orig_openat_2 = (openat_fn_t)resolve_next("__openat_2");
    if (!orig_openat_2) return openat(dirfd, pathname, flags);

    const char *target = get_redirect_path(pathname, flags);
    int res;
    if (target != pathname) {
        res = orig_openat_2(AT_FDCWD, target, flags);
        safe_g_free((void *)target);
    } else {
        res = orig_openat_2(dirfd, pathname, flags);
    }
    return res;
}

/* ========================================================================= */
/* GTK File Chooser Hooks (File dialogs in native GTK / Portal dialogs)      */
/* ========================================================================= */

char *gtk_file_chooser_get_filename(GtkFileChooser *chooser) {
    if (!orig_get_filename) orig_get_filename = (gtk_get_filename_fn)resolve_next("gtk_file_chooser_get_filename");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");

    if (!orig_get_filename) return NULL;
    if (in_hook) return orig_get_filename(chooser);

    in_hook = 1;
    char *orig_res = orig_get_filename(chooser);
    if (!orig_res) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_res;
    }

    char *cleaned = prepare_cleaned_file(orig_res);
    in_hook = 0;

    if (cleaned != orig_res) {
        safe_g_free(orig_res);
        return cleaned;
    }
    return orig_res;
}

GSList *gtk_file_chooser_get_filenames(GtkFileChooser *chooser) {
    if (!orig_get_filenames) orig_get_filenames = (gtk_get_filenames_fn)resolve_next("gtk_file_chooser_get_filenames");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");

    if (!orig_get_filenames) return NULL;
    if (in_hook) return orig_get_filenames(chooser);

    in_hook = 1;
    GSList *orig_list = orig_get_filenames(chooser);
    if (!orig_list) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_list;
    }

    for (GSList *curr = orig_list; curr != NULL; curr = curr->next) {
        if (curr->data) {
            char *cleaned = prepare_cleaned_file((const char *)curr->data);
            if (cleaned != curr->data) {
                safe_g_free(curr->data);
                curr->data = cleaned;
            }
        }
    }
    in_hook = 0;
    return orig_list;
}

GFile *gtk_file_chooser_get_file(GtkFileChooser *chooser) {
    if (!orig_get_file) orig_get_file = (gtk_get_file_fn)resolve_next("gtk_file_chooser_get_file");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");
    init_glib_symbols();

    if (!orig_get_file) return NULL;
    if (in_hook) return orig_get_file(chooser);

    in_hook = 1;
    GFile *orig_file = orig_get_file(chooser);
    if (!orig_file) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_file;
    }

    if (real_g_file_get_path && real_g_file_new_for_path) {
        char *path = real_g_file_get_path(orig_file);
        if (path) {
            char *cleaned = prepare_cleaned_file(path);
            if (cleaned != path) {
                if (real_g_object_unref) real_g_object_unref(orig_file);
                orig_file = real_g_file_new_for_path(cleaned);
                safe_g_free(cleaned);
            }
            safe_g_free(path);
        }
    }
    in_hook = 0;
    return orig_file;
}

GSList *gtk_file_chooser_get_files(GtkFileChooser *chooser) {
    if (!orig_get_files) orig_get_files = (gtk_get_files_fn)resolve_next("gtk_file_chooser_get_files");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");
    init_glib_symbols();

    if (!orig_get_files) return NULL;
    if (in_hook) return orig_get_files(chooser);

    in_hook = 1;
    GSList *orig_list = orig_get_files(chooser);
    if (!orig_list) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_list;
    }

    if (real_g_file_get_path && real_g_file_new_for_path) {
        for (GSList *curr = orig_list; curr != NULL; curr = curr->next) {
            if (curr->data) {
                char *path = real_g_file_get_path((GFile *)curr->data);
                if (path) {
                    char *cleaned = prepare_cleaned_file(path);
                    if (cleaned != path) {
                        if (real_g_object_unref) real_g_object_unref(curr->data);
                        curr->data = real_g_file_new_for_path(cleaned);
                        safe_g_free(cleaned);
                    }
                    safe_g_free(path);
                }
            }
        }
    }
    in_hook = 0;
    return orig_list;
}

char *gtk_file_chooser_get_uri(GtkFileChooser *chooser) {
    if (!orig_get_uri) orig_get_uri = (gtk_get_uri_fn)resolve_next("gtk_file_chooser_get_uri");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");
    init_glib_symbols();

    if (!orig_get_uri) return NULL;
    if (in_hook) return orig_get_uri(chooser);

    in_hook = 1;
    char *orig_uri = orig_get_uri(chooser);
    if (!orig_uri) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_uri;
    }

    if (real_g_filename_from_uri && real_g_filename_to_uri) {
        char *path = real_g_filename_from_uri(orig_uri, NULL, NULL);
        if (path) {
            char *cleaned = prepare_cleaned_file(path);
            if (cleaned != path) {
                safe_g_free(orig_uri);
                orig_uri = real_g_filename_to_uri(cleaned, NULL, NULL);
                safe_g_free(cleaned);
            }
            safe_g_free(path);
        }
    }
    in_hook = 0;
    return orig_uri;
}

GSList *gtk_file_chooser_get_uris(GtkFileChooser *chooser) {
    if (!orig_get_uris) orig_get_uris = (gtk_get_uris_fn)resolve_next("gtk_file_chooser_get_uris");
    if (!orig_get_action) orig_get_action = (gtk_get_action_fn)resolve_next("gtk_file_chooser_get_action");
    init_glib_symbols();

    if (!orig_get_uris) return NULL;
    if (in_hook) return orig_get_uris(chooser);

    in_hook = 1;
    GSList *orig_list = orig_get_uris(chooser);
    if (!orig_list) {
        in_hook = 0;
        return NULL;
    }

    if (orig_get_action && orig_get_action(chooser) != GTK_ACTION_OPEN) {
        in_hook = 0;
        return orig_list;
    }

    if (real_g_filename_from_uri && real_g_filename_to_uri) {
        for (GSList *curr = orig_list; curr != NULL; curr = curr->next) {
            if (curr->data) {
                char *path = real_g_filename_from_uri((const char *)curr->data, NULL, NULL);
                if (path) {
                    char *cleaned = prepare_cleaned_file(path);
                    if (cleaned != path) {
                        safe_g_free(curr->data);
                        curr->data = real_g_filename_to_uri(cleaned, NULL, NULL);
                        safe_g_free(cleaned);
                    }
                    safe_g_free(path);
                }
            }
        }
    }
    in_hook = 0;
    return orig_list;
}

/* Intercept dynamic lookups for Electron & Chromium */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull-compare"
void *dlsym(void *handle, const char *symbol) {
    init_real_dlsym();
    if (!symbol) return NULL;

    if (strcmp(symbol, "gtk_file_chooser_get_filename") == 0) return (void *)gtk_file_chooser_get_filename;
    if (strcmp(symbol, "gtk_file_chooser_get_filenames") == 0) return (void *)gtk_file_chooser_get_filenames;
    if (strcmp(symbol, "gtk_file_chooser_get_file") == 0) return (void *)gtk_file_chooser_get_file;
    if (strcmp(symbol, "gtk_file_chooser_get_files") == 0) return (void *)gtk_file_chooser_get_files;
    if (strcmp(symbol, "gtk_file_chooser_get_uri") == 0) return (void *)gtk_file_chooser_get_uri;
    if (strcmp(symbol, "gtk_file_chooser_get_uris") == 0) return (void *)gtk_file_chooser_get_uris;

    if (strcmp(symbol, "open") == 0) return (void *)open;
    if (strcmp(symbol, "open64") == 0) return (void *)open64;
    if (strcmp(symbol, "openat") == 0) return (void *)openat;
    if (strcmp(symbol, "openat64") == 0) return (void *)openat64;

    if (real_dlsym) {
        return real_dlsym(handle, symbol);
    }
    return NULL;
}

#pragma GCC diagnostic pop
