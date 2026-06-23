
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define N      17669
#define WEIGHT 75

static uint32_t scale_random(uint32_t rand_word, uint32_t range) {
    uint64_t result = (uint64_t)rand_word * (uint64_t)range;
    return (uint32_t)(result >> 32);
}
static uint32_t swap_map  [N];
static uint8_t  is_swapped[N];
static uint32_t seed_words[500];

int main() {

    // ----------------------------------------------------------------
    // Step 1: Read seed words from file (written by testbench)
    // ----------------------------------------------------------------
    //uint32_t seed_words[200];
    int      seed_count = 0;

    FILE* fs = fopen("rtl_seeds.txt", "r");
    if (!fs) {
        printf("ERROR: cannot open rtl_seeds.txt\n");
        return 1;
    }
    while (fscanf(fs, "%u", &seed_words[seed_count]) == 1)
        seed_count++;
    fclose(fs);


    // ----------------------------------------------------------------
    // Step 2: Read RTL P[] output
    // ----------------------------------------------------------------
    uint32_t P_rtl[WEIGHT];
    FILE* fp = fopen("rtl_output.txt", "r");
    if (!fp) {
        printf("ERROR: cannot open rtl_output.txt\n");
        return 1;
    }
    for (int k = 0; k < WEIGHT; k++)
        fscanf(fp, "%u", &P_rtl[k]);
    fclose(fp);

    // printf("\n=== RTL P[] output ===\n");
    // for (int k = 0; k < WEIGHT; k++)
    //     printf("  P_rtl[%d] = %d\n", k, P_rtl[k]);

    // ----------------------------------------------------------------
    // Step 3: Run C reference using EXACT same seeds as RTL
    // ----------------------------------------------------------------
    // uint32_t swap_map  [N];
    // uint8_t  is_swapped[N];
    memset(swap_map,   0, sizeof(swap_map));
    memset(is_swapped, 0, sizeof(is_swapped));

    uint32_t P_ref[WEIGHT];

    printf("\n=== C Reference Model ===\n");
    for (int i = 0; i < WEIGHT; i++) {
        int      seed_idx  = i * 2;
        uint32_t rand_word = (seed_idx < seed_count) ? seed_words[seed_idx] : 0;
        uint32_t range     = N - 1 - i;
        uint32_t offset    = scale_random(rand_word, range);
        uint32_t j         = i + offset;

        uint32_t val_i = is_swapped[i] ? swap_map[i] : (uint32_t)i;
        uint32_t val_j = is_swapped[j] ? swap_map[j] : (uint32_t)j;

        swap_map[i]   = val_j;
        swap_map[j]   = val_i;
        is_swapped[i] = 1;
        is_swapped[j] = 1;
        P_ref[i]      = val_j;

    //     printf("  i=%d seed=0x%08x j=%d P_ref[%d]=%d\n",
    //            i, rand_word, j, i, val_j);
    }

    // ----------------------------------------------------------------
    // Step 4: Compare RTL vs C reference
    // ----------------------------------------------------------------
    int match_cnt    = 0;
    int mismatch_cnt = 0;
    printf("================================================\n");
    printf("  %-6s  %-10s  %-10s  %s\n", "Index", "RTL", "REF", "Result");
    printf("  %-6s  %-10s  %-10s  %s\n", "-----", "---", "---", "------");
 
    for (int k = 0; k < WEIGHT; k++) {
        if (P_rtl[k] == P_ref[k]) {
            printf("  %-6d  %-10u  %-10u  MATCH\n",
                   k, P_rtl[k], P_ref[k]);
            match_cnt++;
        } else {
            printf("  %-6d  %-10u  %-10u  MISMATCH <<<\n",
                   k, P_rtl[k], P_ref[k]);
            mismatch_cnt++;
        }
    }
 
    printf("================================================\n");
    printf("  Matched  : %d / %d\n", match_cnt,    WEIGHT);
    printf("  Mismatched: %d / %d\n", mismatch_cnt, WEIGHT);
    printf("================================================\n");
 
    if (mismatch_cnt == 0)
        printf("  RESULT: ALL INDICES MATCH \n");
    else
        printf("  RESULT: %d MISMATCHES FOUND\n", mismatch_cnt);
 
    printf("================================================\n\n");
 
    
    return 0;
    }