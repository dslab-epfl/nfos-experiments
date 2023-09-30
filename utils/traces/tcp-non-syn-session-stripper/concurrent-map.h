#pragma once

#include <stdbool.h>

// Here the return type of a hash function is assumed to be unsigned = uint32_t
// If you want to change it, you can run find&replace for unsigned in map
// related files, just be careful not to mix the type of the map capacity and
// a couple of other unsigned unrelated values.
typedef unsigned map_key_hash(void* k1);

typedef bool map_keys_equality(void* k1, void* k2);

struct ConcurrentMap;

int concurrent_map_allocate(map_keys_equality* keq,
                            map_key_hash* khash, unsigned capacity,
                            struct ConcurrentMap** map_out);

int concurrent_map_get(struct ConcurrentMap* map, void* key, int* value_out);

void concurrent_map_put(struct ConcurrentMap* map, void* key, int value);

void concurrent_map_erase(struct ConcurrentMap* map, void* key, void** trash);
