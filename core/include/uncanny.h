#ifndef UNCANNY_H
#define UNCANNY_H

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
} up_params;

typedef struct up_planet up_planet;

uint64_t up_seed_from_string(const char *text, size_t length);

up_planet *up_planet_create(const up_params *params);
void up_planet_destroy(up_planet *planet);

uint32_t up_planet_vertex_count(const up_planet *planet);
const float *up_planet_positions(const up_planet *planet); // unit xyz per vertex
const float *up_planet_elevations(const up_planet *planet); // meters per vertex
const uint64_t *up_planet_addresses(const up_planet *planet);
uint32_t up_planet_index_count(const up_planet *planet);
const uint32_t *up_planet_indices(const up_planet *planet);

double up_planet_radius(const up_planet *planet); // meters
float up_planet_sea_level(const up_planet *planet); // meters
float up_planet_min_elevation(const up_planet *planet);
float up_planet_max_elevation(const up_planet *planet);

// Patches: triangles of the subdivided icosahedron, named by level (0 up to
// up_patch_max_level()), base face (0...19), and path (one child index, 0...3, per level,
// most significant first), each drawn as a fixed lattice of finer triangles.
uint32_t up_patch_max_level(void);
uint32_t up_patch_vertex_count(void);
uint32_t up_patch_surface_index_count(void); // the surface's indices come first...
uint32_t up_patch_index_count(void);         // ...then the skirts'
void up_patch_indices(uint32_t *out);        // shared by every patch

// Writes up_patch_vertex_count() vertices of 12 floats: unit direction (3), elevation in
// meters, tangential elevation gradient in meters per radian (3), skirt (0 or 1), and the
// elevation (1) and gradient (3) the parent patch shows there, for blending between levels.
// Pure and thread-safe.
void up_patch_generate(const up_planet *planet, uint32_t level, uint32_t face, uint64_t path,
                       float *out);

// Unit vector toward the sun in the planet's frame, `seconds` after epoch.
void up_planet_sun_direction(const up_planet *planet, double seconds, float out[3]);

#endif
