`timescale 1ns / 1ps


module axi_memory_reader_pkt_functional #(
    parameter integer BYTE_WIDTH  = 8 ,
    parameter integer ADDR_WIDTH  = 32,
    parameter integer BURST_LIMIT = 32
) (
    input  logic                        CLK             ,
    input  logic                        RESET           ,
    //internal interface
    input  logic [    (ADDR_WIDTH-1):0] CMD_ADDRESS     ,
    input  logic [                63:0] CMD_SIZE        ,
    input  logic                        CMD_EMPTY       ,
    output logic                        CMD_RDEN        ,
    // interface to memory
    output logic [      ADDR_WIDTH-1:0] M_AXI_ARADDR    ,
    output logic [                 7:0] M_AXI_ARLEN     ,
    output logic [                 2:0] M_AXI_ARSIZE    ,
    output logic [                 1:0] M_AXI_ARBURST   ,
    output logic                        M_AXI_ARVALID     = 1'b0,
    input  logic                        M_AXI_ARREADY   ,
    input  logic [((BYTE_WIDTH*8)-1):0] M_AXI_RDATA     ,
    input  logic [                 1:0] M_AXI_RRESP     ,
    input  logic                        M_AXI_RLAST     ,
    input  logic                        M_AXI_RVALID    ,
    output logic                        M_AXI_RREADY      = 1'b0,
    // interface to flash
    output logic [((BYTE_WIDTH*8)-1):0] M_AXIS_TDATA    ,
    output logic [    (BYTE_WIDTH-1):0] M_AXIS_TKEEP    ,
    output logic                        M_AXIS_TVALID   ,
    input  logic                        M_AXIS_TREADY   ,
    output logic                        M_AXIS_TLAST    ,
    // время в тактах
    output logic [                63:0] ELAPSED_TIME    ,
    output logic                        READER_BUSY     ,
    output logic [                63:0] TRANSFERRED_SIZE,
    output logic [                31:0] QUERY_COUNT     ,
    output logic [                63:0] DATA_COUNT
);


    localparam integer FIFO_DEPTH             = (BURST_LIMIT <= 16) ? 32 : (BURST_LIMIT*2)   ;
    localparam integer C_AXSIZE_INT           = $clog2(BYTE_WIDTH);
    localparam integer C_AXADDR_INCREMENT_VEC = (BYTE_WIDTH)      ;


    typedef enum {
        IDLE_ST                     ,
        ESTABLISH_ADDR_ST           ,
        READ_FROM_MEMORY_ST         ,
        WAIT_TX_ST             ,
        STUB_ST
    } fsm;

    fsm current_state = IDLE_ST;

    logic [63:0] write_elapsed_size    ;

    logic [63:0] word_counter = '{default:0};
    logic [ 8:0] arlen_reg    = '{default:0};


    logic [((BYTE_WIDTH*8)-1):0] out_din_data = '{default:0};
    logic                        out_din_last = 1'b0        ;
    logic                        out_wren     = 1'b0        ;
    logic                        out_pfull                  ;
    logic                        out_full                   ;



    always_comb begin
        M_AXI_ARSIZE  = C_AXSIZE_INT;
        M_AXI_ARBURST = 2'b01;
    end



    always_ff @(posedge CLK) begin : MGR_BUSY_processing
        case (current_state)
            IDLE_ST : 
                READER_BUSY <= 1'b0;

            default : 
                READER_BUSY <= 1'b1;
                
        endcase // current_state
    end 



    always_ff @(posedge CLK) begin : ELAPSED_TIME_processing 
        if (RESET) begin 
            ELAPSED_TIME <= '{default:0};
        end else begin 

            case (current_state)
                IDLE_ST : 
                    if (!out_pfull) begin 
                        if (!CMD_EMPTY) begin 
                            ELAPSED_TIME <= '{default:0};
                        end else begin 
                            ELAPSED_TIME <= ELAPSED_TIME;
                        end 
                    end else begin 
                        ELAPSED_TIME <= ELAPSED_TIME;
                    end 

                default : 
                    ELAPSED_TIME <= ELAPSED_TIME + 1;

            endcase // current_staSTARTte
        end 
    end 



    always_ff @(posedge CLK) begin : CMD_RDEN_processing 
        if (RESET) begin 
            CMD_RDEN <= 1'b0;
        end else begin 
            case (current_state)
                WAIT_TX_ST : 
                    if (out_pfull) begin 
                        CMD_RDEN <= 1'b0;
                    end else begin 
                        if (word_counter == 0) begin 
                            CMD_RDEN <= 1'b1;
                        end else begin 
                            CMD_RDEN <= 1'b0;
                        end 
                    end 

                IDLE_ST : 
                    if (!out_pfull) begin 
                        if (!CMD_EMPTY) begin 
                            if (CMD_SIZE == 0) begin 
                                CMD_RDEN <= 1'b1;
                            end else begin 
                                CMD_RDEN <= 1'b0;
                            end
                        end else begin 
                            CMD_RDEN <= 1'b0;
                        end 
                    end else begin 
                        CMD_RDEN <= 1'b0;
                    end 

                default: 
                    CMD_RDEN <= 1'b0;

            endcase // current_state

        end 
    end 



    always_ff @(posedge CLK) begin : current_state_processing 
        if (RESET) begin 
            current_state <= IDLE_ST;
        end else begin 
            case (current_state)
                IDLE_ST  : 
                    if (!out_pfull) begin 
                        if (!CMD_EMPTY) begin 
                            if (CMD_SIZE == 0) begin 
                                current_state <= STUB_ST;
                            end else begin 
                                current_state <= ESTABLISH_ADDR_ST;
                            end 
                        end else begin 
                            current_state <= current_state;
                        end 
                    end else begin 
                        current_state <= current_state;
                    end 

                ESTABLISH_ADDR_ST: 
                    current_state <= READ_FROM_MEMORY_ST;

                READ_FROM_MEMORY_ST: 
                    if (M_AXI_RVALID & M_AXI_RREADY & M_AXI_RLAST) begin
                        current_state <= WAIT_TX_ST;
                    end else begin 
                        current_state <= current_state;
                    end 

                WAIT_TX_ST : 
                    if (out_pfull) begin 
                        current_state <= current_state;
                    end else begin 
                        if (word_counter == 0) begin 
                            current_state <= STUB_ST;
                        end else begin 
                            current_state <= ESTABLISH_ADDR_ST;
                        end 
                    end 

                STUB_ST : 
                    current_state <= IDLE_ST;

                default :
                    current_state <= current_state;

            endcase // current_state
        end 
    end 



    always_ff @(posedge CLK) begin : M_AXI_ARADDR_processing
        case (current_state)
            IDLE_ST :
                M_AXI_ARADDR <= CMD_ADDRESS;

            READ_FROM_MEMORY_ST : 
                if (M_AXI_RVALID & M_AXI_RREADY & M_AXI_RLAST)  begin
                    M_AXI_ARADDR <= M_AXI_ARADDR + (arlen_reg << C_AXSIZE_INT);
                end else begin
                    M_AXI_ARADDR <= M_AXI_ARADDR;
                end

            default : 
                M_AXI_ARADDR <= M_AXI_ARADDR;

        endcase
    end



    always_ff @(posedge CLK) begin : M_AXI_ARLEN_processing
        if (RESET) begin 
            M_AXI_ARLEN <= '{default:0};
        end else begin 
            case (current_state)

                ESTABLISH_ADDR_ST : 
                    if (word_counter < BURST_LIMIT) begin 
                        M_AXI_ARLEN <= (word_counter - 1);
                    end else begin 
                        M_AXI_ARLEN <= (BURST_LIMIT-1);
                    end 

                default : 
                    M_AXI_ARLEN <= M_AXI_ARLEN;

            endcase
        end 
    end



    always_ff @(posedge CLK) begin : arlen_reg_processing
        case (current_state)
            ESTABLISH_ADDR_ST : 
                if (word_counter < BURST_LIMIT) begin 
                    arlen_reg <= word_counter;
                end else begin 
                    arlen_reg <= BURST_LIMIT;
                end 

            default : 
                arlen_reg <= arlen_reg;
        endcase
    end



    always_ff @(posedge CLK) begin : M_AXI_ARVALID_processing
        case (current_state)

            ESTABLISH_ADDR_ST : 
                M_AXI_ARVALID <= 1'b1;

            default :
                if (M_AXI_ARVALID & M_AXI_ARREADY) begin 
                    M_AXI_ARVALID <= 1'b0;
                end else begin 
                    M_AXI_ARVALID <= M_AXI_ARVALID;
                end 

        endcase
    end



    always_ff @(posedge CLK) begin : M_AXI_RREADY_processing
        case (current_state)

            ESTABLISH_ADDR_ST : 
                M_AXI_RREADY <= 1'b1;

            READ_FROM_MEMORY_ST : 
                if (M_AXI_RVALID & M_AXI_RLAST & M_AXI_RREADY) begin  
                    M_AXI_RREADY <= 1'b0;
                end else begin
                    M_AXI_RREADY <= M_AXI_RREADY;
                end

            default : 
                M_AXI_RREADY <= 1'b0;
        endcase
    end



    always_ff @(posedge CLK) begin : word_counter_processing
        case (current_state)

            IDLE_ST : 
                if (CMD_SIZE[(C_AXSIZE_INT-1):0] == 0) begin
                    word_counter <= CMD_SIZE[63:C_AXSIZE_INT];
                end else begin
                    word_counter <= CMD_SIZE[63:C_AXSIZE_INT] + 1;
                end

            READ_FROM_MEMORY_ST : 
                if (M_AXI_ARVALID & M_AXI_ARREADY) begin 
                    word_counter <= word_counter - arlen_reg;
                end else begin 
                    word_counter <= word_counter;
                end 

            default : 
                word_counter <= word_counter;

        endcase
    end



    always_ff @(posedge CLK)  begin : TRANSFERRED_SIZE_processing 
        case (current_state)
            IDLE_ST : 
                if (!out_pfull) begin 
                    if (!CMD_EMPTY) begin 
                        TRANSFERRED_SIZE <= '{default:0};
                    end else begin 
                        TRANSFERRED_SIZE <= TRANSFERRED_SIZE;
                    end 
                end else begin 
                    TRANSFERRED_SIZE <= TRANSFERRED_SIZE;
                end 

            default : 
                if (M_AXI_RVALID & M_AXI_RREADY) begin 
                    TRANSFERRED_SIZE <= TRANSFERRED_SIZE + BYTE_WIDTH;
                end else begin 
                    TRANSFERRED_SIZE <= TRANSFERRED_SIZE;
                end 

        endcase // current_state
    end 



    always_ff @(posedge CLK) begin : write_elapsed_size_processing 
        case (current_state)
            IDLE_ST : 
                if (!CMD_EMPTY) begin 
                    if (CMD_SIZE[(C_AXSIZE_INT-1):0] == 0) begin
                        write_elapsed_size <= CMD_SIZE[63:C_AXSIZE_INT] << C_AXSIZE_INT;
                        // write_elapsed_size <= CMD_SIZE[31:C_AXSIZE_INT];
                    end else begin 
                        write_elapsed_size <= (CMD_SIZE[63:C_AXSIZE_INT] + 1) << C_AXSIZE_INT;
                        // write_elapsed_size <= (CMD_SIZE[31:C_AXSIZE_INT] + 1);
                    end 
                end else begin 
                    write_elapsed_size <= write_elapsed_size;
                end 

            READ_FROM_MEMORY_ST : 
                if (M_AXI_RVALID) begin 
                    write_elapsed_size <= (write_elapsed_size - BYTE_WIDTH);
                end else begin 
                    write_elapsed_size <= write_elapsed_size;
                end 

            default :
                write_elapsed_size <= write_elapsed_size;

        endcase // current_state
    end 



    logic [BYTE_WIDTH-1:0] out_din_keep = '{default:1};



    fifo_out_pfull_sync_xpm #(
        .DATA_WIDTH  ((BYTE_WIDTH*8)),
        .MEMTYPE     ("block"       ),
        .DEPTH       (FIFO_DEPTH    ),
        .PFULL_ASSERT(BURST_LIMIT   )
    ) fifo_out_pfull_sync_xpm_inst (
        .CLK          (CLK          ),
        .RESET        (RESET        ),
        .OUT_DIN_DATA (M_AXI_RDATA  ),
        .OUT_DIN_KEEP (out_din_keep ),
        .OUT_DIN_LAST (out_din_last ),
        .OUT_WREN     (M_AXI_RVALID ),
        .OUT_PFULL    (out_pfull    ),
        .OUT_FULL     (out_full     ),
        .M_AXIS_TDATA (M_AXIS_TDATA ),
        .M_AXIS_TKEEP (M_AXIS_TKEEP ),
        .M_AXIS_TVALID(M_AXIS_TVALID),
        .M_AXIS_TLAST (M_AXIS_TLAST ),
        .M_AXIS_TREADY(M_AXIS_TREADY)
    );

    always_comb begin 
        out_din_last = (write_elapsed_size == BYTE_WIDTH) & M_AXI_RVALID & M_AXI_RLAST;
    end 

    always_ff @(posedge CLK) begin : QUERY_COUNT_processing 
        if (RESET) begin 
            QUERY_COUNT <= '{default:0};
        end else begin 
            if (CMD_RDEN) begin 
                QUERY_COUNT <= QUERY_COUNT + 1;
            end else begin 
                QUERY_COUNT <= QUERY_COUNT;
            end 
        end 
    end 

    always_ff @(posedge CLK) begin : DATA_COUNT_processing 
        if (RESET) begin 
            DATA_COUNT <= '{default:0};
        end else begin 
            if (M_AXI_RVALID & M_AXI_RREADY) begin 
                DATA_COUNT <= DATA_COUNT + BYTE_WIDTH;
            end else begin 
                DATA_COUNT <= DATA_COUNT;
            end 
        end 
    end 


endmodule
