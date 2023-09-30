#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <netinet/in.h>
#include <netinet/ip.h>
#include <net/if.h>
#include <netinet/if_ether.h>
#include <net/ethernet.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <arpa/inet.h>

#include <pcap/pcap.h>

#include "concurrent-map.h"

#define FLOW_BLACKLIST_CAPACITY 2097152
static struct ConcurrentMap *flow_whitelist;

typedef struct flow_id {
  uint32_t src_ip;
  uint32_t dst_ip;
  uint16_t src_port;
  uint16_t dst_port;
  uint8_t proto;
} flow_id_t;

/* map auxiliary func */

static bool flow_id_eq(void* a, void* b) {
  flow_id_t *id1 = (flow_id_t *) a;
  flow_id_t *id2 = (flow_id_t *) b;
  return (id1->src_ip == id2->src_ip)
     && (id1->dst_ip == id2->dst_ip)
     && (id1->src_port == id2->src_port)
     && (id1->dst_port == id2->dst_port)
     && (id1->proto == id2->proto);
}

static unsigned flow_id_hash(void* obj) {
  flow_id_t *id = (flow_id_t *) obj;

  unsigned hash = 0;
  hash = __builtin_ia32_crc32si(hash, id->src_ip);
  hash = __builtin_ia32_crc32si(hash, id->dst_ip);
  hash = __builtin_ia32_crc32si(hash, id->src_port);
  hash = __builtin_ia32_crc32si(hash, id->dst_port);
  hash = __builtin_ia32_crc32si(hash, id->proto);
  return hash;
}

// This func assumes the input trace is filtered to only contain ipv4 packets
static void parse_pkt(const u_char *pkt, flow_id_t *id_out,
                      uint8_t *tcp_flag_out) {
  const struct ip *ipHeader = (struct ip*)(pkt + sizeof(struct ether_header));
  id_out->src_ip = ntohl(ipHeader->ip_src.s_addr);
  id_out->dst_ip = ntohl(ipHeader->ip_dst.s_addr);

  id_out->proto = ipHeader->ip_p;
  if (id_out->proto == IPPROTO_TCP) {
    const struct tcphdr* tcpHeader = (struct tcphdr*)((u_char *)ipHeader 
                                                      + sizeof(struct ip));
    id_out->src_port = ntohs(tcpHeader->source);
    id_out->dst_port = ntohs(tcpHeader->dest);
    *tcp_flag_out = tcpHeader->th_flags;
  } else if (id_out->proto == IPPROTO_UDP) {
    const struct udphdr* udpHeader = (struct udphdr*)((u_char *)ipHeader 
                                                      + sizeof(struct ip));
    id_out->src_port = ntohs(udpHeader->source);
    id_out->dst_port = ntohs(udpHeader->dest);
  }
}

static void pkt_filter(u_char *user, const struct pcap_pkthdr *h,
                       const u_char *pkt) {
  pcap_dumper_t *handle = (pcap_dumper_t *)user;
  flow_id_t id = { .proto = 0 };
  uint8_t tcp_flag = 0;

  parse_pkt(pkt, &id, &tcp_flag);

  bool discard = false;

  // let all non-TCP packets pass
  if (id.proto == IPPROTO_TCP) {
    int map_val;
    if (!concurrent_map_get(flow_whitelist, &id, &map_val)) {
      if ((tcp_flag & TH_SYN) && !(tcp_flag & TH_ACK)) {
        concurrent_map_put(flow_whitelist, &id, 1);
      // discard non-SYN or SYN-ACK packets before a SYN
      } else {
        discard = true;
      }
    }
  }

  // Debug
  // if (id.proto == 0)
  //   printf("non tcp/udp\n");
  // else
  //   printf("%u, %u, %d, %d, %d\n", id.src_ip, id.dst_ip, id.src_port, id.dst_port, id.proto);
  // int map_val;
  // if (concurrent_map_get(flow_whitelist, &id, &map_val))
  //   pcap_dump(handle, h, pkt);
  // end debug
  if (!discard)
    pcap_dump(handle, h, pkt);
}

int main(int argc, char *argv[]) {
  char *input_pcap, *output_pcap;
  if (argc != 3) {
    printf("incorrect args\n");
    return -1;
  } else {
    input_pcap = argv[1];
    output_pcap = argv[2];
  }

  char errbuf[PCAP_ERRBUF_SIZE];

  pcap_t *handle = pcap_open_offline(input_pcap, errbuf);
  if (!handle) {
    printf("%s\n", errbuf);
    return -1;
  }
  pcap_dumper_t *output_handle = pcap_dump_open(handle, output_pcap);
  if (!output_handle) {
    printf("%s\n", pcap_geterr(handle));
    return -1;
  }

  concurrent_map_allocate(flow_id_eq, flow_id_hash, FLOW_BLACKLIST_CAPACITY,
                         &flow_whitelist);

  // Debug
  /* flow_id_t whitelist_flow_one = {
    .src_ip = 1906439972,
    .dst_ip = 737992821,
    .src_port = 49971,
    .dst_port = 443,
    .proto = 6
  };
  flow_id_t whitelist_flow_two = {
    .src_ip = 1314024724,
    .dst_ip = 2300578394,
    .src_port = 60861,
    .dst_port = 28710,
    .proto = 17
  };
  concurrent_map_put(flow_whitelist, &whitelist_flow_one, 1);
  concurrent_map_put(flow_whitelist, &whitelist_flow_two, 2); */
  // end debug

  pcap_loop(handle, -1, pkt_filter, (u_char *)output_handle);

  pcap_close(handle);
  pcap_dump_close(output_handle);
  return 0;
}