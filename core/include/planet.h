#ifndef PLANET_H
#define PLANET_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t seed;
    double radius_scale; // relative to Earth
    double region_scale; // >= 1, relative to Earth
    double sea_level;    // 0...1 of the surface elevation range
    double axial_tilt;   // degrees
    double day_length;   // relative to Earth
    double year_length;  // relative to Earth
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

double pl_planet_radius(const pl_planet *planet); // meters
float pl_planet_sea_level(const pl_planet *planet); // meters
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

// Unit vector toward the sun in the planet's frame, `seconds` after epoch.
void pl_planet_sun_direction(const pl_planet *planet, double seconds, float out[3]);

#endif
