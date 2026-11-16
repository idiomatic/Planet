#ifndef PLANET_H
#define PLANET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Exactly the inputs that generate a planet; the view's parameters (radius, sea level, the
// orbit, and so on) are the app's.
typedef struct {
    uint64_t seed;
    double region_scale; // >= 1, relative to Earth
} pl_params;

typedef struct pl_planet pl_planet;

uint64_t pl_seed_from_string(const char *text, size_t length);

pl_planet *pl_planet_create(const pl_params *params);
void pl_planet_destroy(pl_planet *planet);

uint32_t pl_planet_vertex_count(const pl_planet *planet); // of the coarse mesh

// The surface as the view shows it, with relief exaggerated `exaggeration` percent and the sea
// at `sea_level` percent of the elevation range; lengths in radii of the displayed planet.
typedef struct {
    float scale;             // radii per meter of elevation, with exaggeration
    float sea_level;         // meters
    float floor_radius;      // radii: the camera stays above the highest point
    float air_planet_radius; // meters: the planet the air sees (relief taken as at least 100%)
    float air_top;           // radii: the top of the air
} pl_surface;

pl_surface pl_planet_surface(const pl_planet *planet, double exaggeration, double sea_level);
void pl_planet_peak(const pl_planet *planet, float out[3]); // highest coarse vertex, unit
float pl_planet_min_elevation(const pl_planet *planet);
float pl_planet_max_elevation(const pl_planet *planet);

// Patches: triangles of the subdivided icosahedron, named by level (0–8), base face (0...19),
// and path (one child index, 0...3, per level, most significant first), each drawn as a fixed
// lattice of finer triangles.
uint32_t pl_patch_vertex_count(void);
uint32_t pl_patch_float_count(void); // per patch: vertex count × 12
uint32_t pl_patch_surface_index_count(void); // the surface's indices come first...
uint32_t pl_patch_index_count(void);         // ...then the skirts'
void pl_patch_indices(uint32_t *out);        // shared by every patch

// Writes pl_patch_vertex_count() vertices of 12 floats: unit direction (3), elevation in
// meters, tangential elevation gradient in meters per radian (3), skirt (0 or 1), and the
// elevation (1) and gradient (3) the parent patch shows there, for blending between levels.
// Pure and thread-safe.
// Given its parent's vertices (or NULL), copies the points they share (every other lattice
// point) instead of computing them, with the same result for about 30% less work.
void pl_patch_generate(const pl_planet *planet, uint32_t level, uint32_t face, uint64_t path,
                       const float *parent, float *out);

// Level of detail: chooses the patches to draw for a view and keeps the cache's bookkeeping.
// The caller lends vertex storage per slot (pl_lod_storage) and generates requested patches
// (pl_patch_generate, on any thread), installing them as they arrive; or a synchronous
// selection generates everything it needs. Not thread-safe; use from one thread.
typedef struct {
    uint32_t level;
    uint32_t face;
    uint64_t path;
} pl_patch_key;

typedef struct {
    uint32_t slot;
    float skirt_depth; // radii
    float parent_edge; // the parent's lattice triangle edge, radii (0 for a base face)
} pl_lod_draw;

typedef struct {
    uint32_t visited;   // cached patches the last selection used
    uint32_t cached;
    uint32_t pending;   // requested, not yet installed or cancelled
    uint32_t generated; // installed since the last selection began
    uint64_t cached_bytes;
    double generation_seconds; // total, generating synchronously
} pl_lod_stats;

// Vertex storage the caller lends per slot, called back only during pl_lod_* calls (never
// from pl_lod_destroy). acquire returns pl_patch_vertex_count() × 12 floats for the slot, lent
// until release, or NULL if none can be had.
typedef struct {
    void *context;
    float *(*acquire)(void *context, uint32_t slot);
    void (*release)(void *context, uint32_t slot);
} pl_lod_storage;

typedef struct pl_lod pl_lod;

// Generates the 20 base patches. `scale` is radii per meter of elevation (with exaggeration);
// `sea_level` is in meters.
pl_lod *pl_lod_create(const pl_planet *planet, const pl_lod_storage *storage, float scale,
                      float sea_level);
void pl_lod_destroy(pl_lod *lod);
void pl_lod_set_surface(pl_lod *lod, float scale, float sea_level); // refits every patch
void pl_lod_set_detail(pl_lod *lod, float target_pixels);
void pl_lod_set_capacity_bytes(pl_lod *lod, uint64_t bytes);
// Copies a patch generated elsewhere into storage. Returns its slot, -1 if it's already cached,
// or -2 if out of memory or storage.
int64_t pl_lod_install(pl_lod *lod, pl_patch_key key, const float *vertices);
// Selects for a view (column-major view-projection, reverse Z, no far plane): the patches to
// draw, and up to `max_in_flight` pending requests (most visible first) or, when
// `synchronous`, none, having generated every missing patch; each list is valid until the
// next selection. Evicts beyond the capacity. Returns false if out of memory or storage.
bool pl_lod_select(pl_lod *lod, const float view_projection[16], const float camera[3],
                   float pixels_per_radian, uint32_t max_in_flight, bool synchronous);
// Copies the cached parent's vertices (pl_patch_float_count() floats) to generate `key` from
// on another thread; false if its parent isn't cached.
bool pl_lod_parent_vertices(pl_lod *lod, pl_patch_key key, float *out);
const pl_lod_draw *pl_lod_draws(pl_lod *lod, uint32_t *count);
const pl_patch_key *pl_lod_requests(pl_lod *lod, uint32_t *count);
pl_lod_stats pl_lod_stats_get(pl_lod *lod);

// Unit vector toward the sun in the planet's frame, `seconds` after epoch.
// A pure function of the orbit (tilt in degrees, day and year lengths relative to Earth's).
// Seconds into the first day, sampled `samples` times from 0, when the sun's cosine at `point`
// (from its zenith) first lies in [lo, hi], or is nearest
// `target`. Return false when there's no such time (no spin, or never in range).
bool pl_sun_time_first(double axial_tilt, double day_length, double year_length,
                       const double point[3], double lo, double hi, uint32_t samples,
                       double *seconds);
bool pl_sun_time_nearest(double axial_tilt, double day_length, double year_length,
                         const double point[3], double target, uint32_t samples, double *seconds);
void pl_sun_direction(double axial_tilt, double day_length, double year_length, double seconds,
                      float out[3]);

#endif
