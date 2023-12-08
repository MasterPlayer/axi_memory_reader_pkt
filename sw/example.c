#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"

#include <xscugic.h>

#define READING_BASEADDR_BASE 0x10000000


typedef struct {
	uint32_t reset_reg;
	uint32_t memory_baseaddr_lo;
	uint32_t memory_baseaddr_hi;
	uint32_t memory_size_lo;
	uint32_t memory_size_hi;
	uint32_t ctrl_reg;
	uint32_t query_fifo_volume;
	uint32_t query_fifo_limit;
	uint32_t transferred_size_lo;
	uint32_t transferred_size_hi;
	uint32_t freq_hz;
	uint32_t valid_count;
	uint32_t query_count;
	uint32_t data_count_lo;
	uint32_t data_count_hi;
} memory_reader;

int main() {

	init_platform();

    volatile int perform_reading = 0;
    volatile int divide_factor = 65536;
    volatile int dump_statistics = 0;
    uint64_t counter = 0;
    int loop_reset = 0;

	memory_reader *rd_ptr = (memory_reader*)0x44A00000;

	uint32_t query_fifo_volume = rd_ptr->query_fifo_volume;
	uint32_t query_fifo_limit = rd_ptr->query_fifo_limit;

    uint32_t reading_baseaddr = READING_BASEADDR_BASE;
    uint32_t reading_words = (rand() % divide_factor);
    uint32_t reading_bytes = reading_words << 3;

    while(1){
		if (perform_reading) {

			query_fifo_volume = rd_ptr->query_fifo_volume;
			query_fifo_limit = rd_ptr->query_fifo_limit;

			if (query_fifo_volume < query_fifo_limit){
				if (loop_reset == query_fifo_limit*4){
					
					loop_reset = 0;
					reading_baseaddr = READING_BASEADDR_BASE;

				}else{
					
					uint64_t* data = (uint64_t*)reading_baseaddr;
					
					for (int i = 0; i < reading_words; i++){
						data[i] = counter;
						counter++;
					}

					Xil_DCacheFlushRange(reading_baseaddr, reading_bytes);

					rd_ptr->memory_baseaddr_lo = reading_baseaddr;
					rd_ptr->memory_size_lo = reading_bytes;
					rd_ptr->ctrl_reg = 0x00000001;

					reading_baseaddr = reading_baseaddr + reading_bytes;
					reading_words = (rand() % divide_factor);
					
					while (reading_words == 0) {
						reading_words = (rand() % divide_factor);
					}
					
					reading_bytes = reading_words << 3;
					
					loop_reset++;
					
					if (dump_statistics){
						printf("[%2d/%2d] address = 0x%08x size = %7d words(%7d bytes)\r\n", rd_ptr->query_fifo_volume, query_fifo_limit, reading_baseaddr, reading_words, reading_bytes);
					}
				}
			}
		}
	}

    cleanup_platform();
    return 0;
}


