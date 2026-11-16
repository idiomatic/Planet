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

uint32_t pl_planet_vertex_count(const pl_planet *planet);
const float *pl_planet_positions(const pl_planet *planet); // unit xyz per vertex
const float *pl_planet_elevations(const pl_planet *planet); // meters per vertex
const uint64_t *pl_planet_addresses(const pl_planet *planet);
uint32_t pl_planet_index_count(const pl_planet *planet);
const uint32_t *pl_planet_indices(const pl_planet *planet);

void pl_planet_peak(const pl_planet *planet, float out[3]); // highest coarse vertex, unit
float pl_planet_min_elevation(const pl_planet *planet);
float pl_planet_max_elevation(const pl_planet *planet);

// Patches: triangles of the subdivided icosahedron, named by level (0 up to
// pl_patch_max_level()), base face (0...19), and path (one child index, 0...3, per level,
// most significant first), each drawn as a fixed lattice of finer triangles.
uint32_t pl_patch_max_level(void);
uint32_t pl_patch_vertex_count(void);
uint32_t pl_patch_surface_index_count(void); // the surface's indices come first...
uint32_t pl_patch_index_count(void);         // ...then the skirts'
void pl_patch_indices(uint32_t *out);        // shared by every patch

// Writes pl_patch_vertex_count() vertices of 12 floats: unit direction (3), elevation in
// meters, tangential elevation gradient in meters per radian (3), skirt (0 or 1), and the
// elevation (1) and gradient (3) the parent patch shows there, for blending between levels.
// Pure and thread-safe.
void pl_patch_generate(const pl_planet *planet, uint32_t level, uint32_t face, uint64_t path,
                       float *out);

// Level of detail: chooses the patches to draw for a view and keeps the cache's bookkeeping.
// The caller generates patches (pl_patch_generate) and owns their vertices: pl_lod_install
// borrows them until their slot is reported evicted. Not thread-safe; use from one thread.
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
    uint32_t visited; // cached patches the last selection used
    uint32_t cached;
    uint32_t pending; // requested, not yet installed or cancelled
} pl_lod_stats;

typedef struct pl_lod pl_lod;

// `scale` is radii per meter of elevation (with exaggeration); `sea_level` is in meters.
pl_lod *pl_lod_create(float scale, float sea_level);
void pl_lod_destroy(pl_lod *lod);
void pl_lod_set_surface(pl_lod *lod, float scale, float sea_level); // refits every patch
void pl_lod_set_detail(pl_lod *lod, float target_pixels);
void pl_lod_set_capacity(pl_lod *lod, uint32_t patches);
// Returns the patch's slot, -1 if it's already cached, or -2 if out of memory.
int64_t pl_lod_install(pl_lod *lod, pl_patch_key key, const float *vertices);
void pl_lod_cancel(pl_lod *lod, pl_patch_key key); // a request that won't be installed
// Selects for a view (column-major view-projection, reverse Z, no far plane): the patches to
// draw, up to `max_in_flight` pending requests (most visible first), and evicted slots, each
// valid until the next selection. Returns false if out of memory.
bool pl_lod_select(pl_lod *lod, const float view_projection[16], const float camera[3],
                   float pixels_per_radian, uint32_t max_in_flight);
const pl_lod_draw *pl_lod_draws(pl_lod *lod, uint32_t *count);
const pl_patch_key *pl_lod_requests(pl_lod *lod, uint32_t *count);
const uint32_t *pl_lod_evicted(pl_lod *lod, uint32_t *count);
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
