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

#include <linux/types.h>

static inline __sum16 csum16_add(__sum16 csum, __be16 addend)
{
	__u16 res = (__u16)csum;

	res += (__u16)addend;
	return (__sum16)(res + (res < (__u16)addend));
}

static inline __sum16 csum16_sub(__sum16 csum, __be16 addend)
{
	return csum16_add(csum, ~addend);
}

/* Implements RFC 1624 (Incremental Internet Checksum)
 * 3. Discussion states :
 *     HC' = ~(~HC + ~m + m')
 *  m : old value of a 16bit field
 *  m' : new value of a 16bit field
 */
static inline void csum_replace2(__sum16 *sum, __be16 old, __be16 new)
{
  *sum = ~csum16_add(csum16_sub(~(*sum), old), new);
}


typedef struct flow_id {
  uint32_t src_ip;
  uint32_t dst_ip;
  uint16_t src_port;
  uint16_t dst_port;
  uint8_t proto;
} flow_id_t;

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

static void pkt_filter(u_char *user, struct pcap_pkthdr *h,
                       u_char *pkt) {
  pcap_dumper_t *handle = (pcap_dumper_t *)user;

  struct ip *ipHeader = (struct ip*)(pkt + sizeof(struct ether_header));
  int diff;

  uint8_t proto = ipHeader->ip_p;
  if (proto == IPPROTO_UDP) {
    struct udphdr* udpHeader = (struct udphdr*)((u_char *)ipHeader 
                                                + sizeof(struct ip));
    // strip udp payload
    diff = ntohs(ipHeader->ip_len) - 4 * ipHeader->ip_hl - 8;
    udpHeader->len = htons(8);

    // disable udp checksum
    udpHeader->uh_sum = 0;

  } else if (proto == IPPROTO_TCP) {
    struct tcphdr* tcpHeader = (struct tcphdr*)((u_char *)ipHeader 
                                                + sizeof(struct ip));
    
    // strip tcp payload
    diff = ntohs(ipHeader->ip_len) - 4 * ipHeader->ip_hl - 4 * (uint16_t)tcpHeader->th_off;

    // update tcp checksum
    /*unsigned short old_tcp_len_h = ntohs(ipHeader->ip_len) - 4 * ipHeader->ip_hl;
    unsigned short new_tcp_len_h = 4 * (uint16_t)tcpHeader->th_off;
    csum_replace2(&(tcpHeader->th_sum), htons(old_tcp_len_h), htons(new_tcp_len_h));*/

  } else {
    diff = 0;

  }

  // Update l3 length info and checksum
  unsigned short old_ip_len = ipHeader->ip_len;
  unsigned short new_ip_len_h = ntohs(ipHeader->ip_len) - diff;
  ipHeader->ip_len = htons(new_ip_len_h);
  csum_replace2(&(ipHeader->ip_sum), old_ip_len, ipHeader->ip_len);
 
  // Update l2 length
  h->len = h->len - diff;

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

  pcap_loop(handle, -1, pkt_filter, (u_char *)output_handle);

  pcap_close(handle);
  pcap_dump_close(output_handle);
  return 0;
}
