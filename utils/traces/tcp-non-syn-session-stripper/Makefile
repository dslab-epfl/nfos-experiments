all:
	gcc -std=gnu11 -msse4.2 -O3 main.c concurrent-map.c -lpcap -o non-syn-sess-stripper

.PHONY: clean

clean:
	rm -rf non-syn-sess-stripper
