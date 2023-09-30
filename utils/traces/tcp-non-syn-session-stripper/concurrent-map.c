// Taken from nfos's concurrent map, but it's not really concurrent now...

#include "concurrent-map.h"

#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

struct ConcurrentMap {
  int* busybits;
  void** keyps;
  unsigned* khs;
  int* chns;
  int* vals;
  unsigned capacity;
  map_keys_equality* keys_eq;
  map_key_hash* khash;
};

static inline unsigned rehash(unsigned int x) {
  return x;
}

int concurrent_map_allocate(map_keys_equality* keq, map_key_hash* khash, unsigned capacity, struct ConcurrentMap** _map) {
  struct ConcurrentMap* map = (struct ConcurrentMap*)malloc(sizeof(struct ConcurrentMap));
  if (map == NULL) {
    return 0;
  }
  map->busybits = (int*)malloc(sizeof(int) * (int)capacity);
  if (map->busybits == NULL) {
    free((void*)map);
    return 0;
  }
  map->keyps = (void**)malloc(sizeof(void*) * (int)capacity);
  if (map->keyps == NULL) {
    free((void*)map->busybits);
    free((void*)map);
    return 0;
  }
  map->khs = (unsigned*)malloc(sizeof(unsigned) * (int)capacity);
  if (map->khs == NULL) {
    free((void*)map->keyps);
    free((void*)map->busybits);
    free((void*)map);
    return 0;
  }
  map->chns = (int*)malloc(sizeof(int) * (int)capacity);
  if (map->chns == NULL) {
    free((void*)map->khs);
    free((void*)map->keyps);
    free((void*)map->busybits);
    free((void*)map);
    return 0;
  }
  map->vals = (int*)malloc(sizeof(int) * (int)capacity);
  if (map->vals == NULL) {
    free((void*)map->chns);
    free((void*)map->khs);
    free((void*)map->keyps);
    free((void*)map->busybits);
    free((void*)map);
    return 0;
  }
  map->capacity = capacity;
  map->keys_eq = keq;
  map->khash = khash;
  for (unsigned i = 0; i < capacity; i++) {
    map->busybits[i] = 0;
    map->chns[i] = 0;
  }
  *_map = map;
  return 1;
}

int concurrent_map_get(struct ConcurrentMap* map, void* key, int* value) {
  unsigned hash = rehash(map->khash(key));
  unsigned start = hash & (map->capacity - 1);
  for (unsigned i = 0; i < map->capacity; i++) {
    unsigned index = (start + i) & (map->capacity - 1);
    if (map->busybits[index] != 0 && map->khs[index] == hash) {
      if (map->keys_eq(map->keyps[index], key)) {
        *value = map->vals[index];
        return 1;
      }
    } else if (map->chns[index] == 0) {
      return 0;
    }
  }
  return 0;
}

void concurrent_map_put(struct ConcurrentMap* map, void* key, int value) {
  unsigned hash = rehash(map->khash(key));
  unsigned start = hash & (map->capacity - 1);
  for (unsigned i = 0; i < map->capacity; i++) {
    unsigned index = (start + i) & (map->capacity - 1);
    if (map->busybits[index] == 0) {
      map->busybits[index] = 1;
      map->keyps[index] = key;
      map->khs[index] = hash;
      map->vals[index] = value;
      return;
    }
    map->chns[index] += 1;
  }
  return;
}

void concurrent_map_erase(struct ConcurrentMap* map, void* key, void** trash) {
  unsigned hash = rehash(map->khash(key));
  unsigned start = hash & (map->capacity - 1);
  for (unsigned i = 0; i < map->capacity; i++) {
    unsigned index = (start + i) & (map->capacity - 1);
    if (map->busybits[index] != 0 && map->khs[index] == hash) {
      if (map->keys_eq(map->keyps[index], key)) {
        map->busybits[index] = 0;
        *trash = map->keyps[index];
        return;
      }
    }
    map->chns[index] -= 1;
  }
  return;
}
