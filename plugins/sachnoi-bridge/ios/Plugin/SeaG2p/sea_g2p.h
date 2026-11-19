#ifndef SEA_G2P_H
#define SEA_G2P_H

/* Giao diện C của sea-g2p (Rust) — tra từ điển sea_g2p.bin, chuẩn hoá + phiên âm
   tiếng Việt cho engine VieNeu. Mọi chuỗi trả về thuộc về caller, phải giải
   phóng bằng sea_g2p_string_free. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SeaG2p SeaG2p;

const char *sea_g2p_last_error(void);
SeaG2p *sea_g2p_open(const char *dict_path);
void sea_g2p_close(SeaG2p *handle);
void sea_g2p_string_free(char *text);
char *sea_g2p_phonemize(SeaG2p *handle, const char *text, int32_t punc_norm);
char *sea_g2p_normalize(SeaG2p *handle, const char *text, int32_t punc_norm);
int32_t sea_g2p_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* SEA_G2P_H */
