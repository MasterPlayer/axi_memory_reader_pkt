`timescale 1 ns / 1 ps

module axi_memory_reader_pkt #(
    parameter integer BYTE_WIDTH       = 8        ,
    parameter integer ADDR_WIDTH       = 32       ,
    parameter integer BURST_LIMIT      = 32       ,
    parameter integer FREQ_HZ          = 100000000,
    parameter integer CMD_FIFO_DEPTH   = 64       ,
    parameter string  CMD_FIFO_MEMTYPE = "block"
) (
    input  logic                        CLK          ,
    input  logic                        RESET        ,
    //
    input        [                 5:0] S_AXI_AWADDR ,
    input        [                 2:0] S_AXI_AWPROT ,
    input                               S_AXI_AWVALID,
    output logic                        S_AXI_AWREADY,
    input        [                31:0] S_AXI_WDATA  ,
    input        [                 3:0] S_AXI_WSTRB  ,
    input                               S_AXI_WVALID ,
    output logic                        S_AXI_WREADY ,
    output logic [                 1:0] S_AXI_BRESP  ,
    output logic                        S_AXI_BVALID ,
    input                               S_AXI_BREADY ,
    input        [                 5:0] S_AXI_ARADDR ,
    input        [                 2:0] S_AXI_ARPROT ,
    input                               S_AXI_ARVALID,
    output logic                        S_AXI_ARREADY,
    output logic [                31:0] S_AXI_RDATA  ,
    output logic [                 1:0] S_AXI_RRESP  ,
    output logic                        S_AXI_RVALID ,
    input                               S_AXI_RREADY ,
    // interface to memory
    output logic [      ADDR_WIDTH-1:0] M_AXI_ARADDR ,
    output logic [                 7:0] M_AXI_ARLEN  ,
    output logic [                 2:0] M_AXI_ARSIZE ,
    output logic [                 1:0] M_AXI_ARBURST,
    output logic                        M_AXI_ARVALID,
    input  logic                        M_AXI_ARREADY,
    input  logic [((BYTE_WIDTH*8)-1):0] M_AXI_RDATA  ,
    input  logic [                 1:0] M_AXI_RRESP  ,
    input  logic                        M_AXI_RLAST  ,
    input  logic                        M_AXI_RVALID ,
    output logic                        M_AXI_RREADY ,
    // interface to flash
    output logic [((BYTE_WIDTH*8)-1):0] M_AXIS_TDATA ,
    output logic [    (BYTE_WIDTH-1):0] M_AXIS_TKEEP ,
    output logic                        M_AXIS_TVALID,
    input  logic                        M_AXIS_TREADY,
    output logic                        M_AXIS_TLAST
);

    localparam integer ADDR_LSB            = 2;
    localparam integer ADDR_OPT            = 3;
    localparam integer RESET_COUNTER_LIMIT = 5;
    //
    localparam integer CMD_FIFO_WIDTH = ADDR_WIDTH + 64; // ADDRESS WIDTH OF CURRENT_ADDRESS + TRANSFERRED_SIZE

    logic [14:0][31:0] register;

    logic        reset_func                  ;
    logic [31:0] reset_counter = '{default:0};

    logic [63:0] memory_fifo_baseaddr;
    logic [63:0] memory_fifo_size    ;
    logic        memory_fifo_enable  ;

    logic [ADDR_WIDTH-1:0] memory_baseaddr  ;
    logic [          63:0] memory_size      ;
    logic                  memory_fifo_empty;
    logic                  memory_fifo_rden ;

    logic        status             ;

    logic [63:0] elapsed_time;
    logic        reader_busy ;

    logic [31:0] query_fifo_volume;

    logic [63:0] transferred_size;

    logic [31:0] query_count;
    logic [63:0] data_count ;

    logic [31:0] timer           = '{default:0};
    logic [31:0] valid_count     = '{default:0};
    logic [31:0] valid_count_reg = '{default:0};

    logic aw_en = 1'b1;



    always_comb begin : to_user_logic_assignment_group
        memory_fifo_baseaddr[31:0]  = register[1];
        memory_fifo_baseaddr[63:32] = register[2];
        memory_fifo_size[31:0]      = register[3];
        memory_fifo_size[63:32]     = register[4];
    end 



    always_comb begin : from_usr_logic_assignment_group
        register[0] = '{default:0};
        // register[14]                = ack_count_reg      ;
        register[5][31:24] = BYTE_WIDTH;
        register[5][23:18] = '{default:0};
        register[5][16] = reader_busy;
        register[5][17] = 1'b0;
        register[5][15:0] = '{default:0};

        register[6] = query_fifo_volume;
        register[7] = CMD_FIFO_DEPTH;
        register[8] = transferred_size[31: 0];
        register[9] = transferred_size[63:32];
        register[10] = FREQ_HZ;

        register[11] = valid_count_reg;
        register[12] = query_count;

        register[13] = data_count[31:0];
        register[14] = data_count[63:32];

    end 




    always_ff @(posedge CLK) begin : reset_processing
        if (RESET) begin
            reset_func <= 1'b1;
        end else begin
            if (reset_counter < RESET_COUNTER_LIMIT) begin
                reset_func <= 1'b1;
            end else begin
                reset_func <= 1'b0;
            end
        end
    end  



    always_ff @(posedge CLK) begin : reset_counter_processing 
        if (RESET) begin 
            reset_counter <= '{default:0};
        end else begin 
            if (reset_counter < RESET_COUNTER_LIMIT) begin 
                reset_counter <= reset_counter + 1;
            end else begin 
                if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY) begin 
                    if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h00) begin 
                        if (S_AXI_WDATA[0]) begin 
                            reset_counter <= '{default:0};
                        end 
                    end 
                end 
            end 
        end 
    end 



    always_ff @(posedge CLK) begin : memory_fifo_enable_processing  
        if (RESET | reset_func ) begin 
            memory_fifo_enable <= 1'b0;
        end else begin 
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY) begin
                if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h05) begin
                    if (S_AXI_WSTRB[0] == 1'b1) begin 
                        memory_fifo_enable <= S_AXI_WDATA[0];
                    end else begin 
                        memory_fifo_enable <= 1'b0;
                    end 
                end else begin 
                    memory_fifo_enable <= 1'b0;
                end 
            end else begin 
                memory_fifo_enable <= 1'b0;
            end 
        end  
    end 



    /**/
    always_ff @(posedge CLK) begin : aw_en_processing 
        if (RESET)
            aw_en <= 1'b1;
        else
            if (!S_AXI_AWREADY & S_AXI_AWVALID & S_AXI_WVALID & aw_en)
                aw_en <= 1'b0;
            else
                if (S_AXI_BREADY & S_AXI_BVALID)
                    aw_en <= 1'b1;
    end 



    /**/
    always_ff @(posedge CLK) begin : S_AXI_AWREADY_processing 
        if (RESET)
            S_AXI_AWREADY <= 1'b0;
        else
            if (!S_AXI_AWREADY & S_AXI_AWVALID & S_AXI_WVALID & aw_en)
                S_AXI_AWREADY <= 1'b1;
            else 
                S_AXI_AWREADY <= 1'b0;
    end 



    always_ff @(posedge CLK) begin : S_AXI_WREADY_processing 
        if (RESET)
            S_AXI_WREADY <= 1'b0;
        else
            if (!S_AXI_WREADY & S_AXI_WVALID & S_AXI_AWVALID & aw_en)
                S_AXI_WREADY <= 1'b1;
            else
                S_AXI_WREADY <= 1'b0;

    end 



    always_ff @(posedge CLK) begin : S_AXI_BVALID_processing
        if (RESET)
            S_AXI_BVALID <= 1'b0;
        else
            if (S_AXI_WVALID & S_AXI_WREADY & S_AXI_AWVALID & S_AXI_AWREADY & ~S_AXI_BVALID)
                S_AXI_BVALID <= 1'b1;
            else
                if (S_AXI_BVALID & S_AXI_BREADY)
                    S_AXI_BVALID <= 1'b0;

    end 



    always_ff @(posedge CLK) begin : S_AXI_ARREADY_processing 
        if (RESET)
            S_AXI_ARREADY <= 1'b0;
        else
            if (!S_AXI_ARREADY & S_AXI_ARVALID)
                S_AXI_ARREADY <= 1'b1;
            else
                S_AXI_ARREADY <= 1'b0;
            
    end



    always_ff @(posedge CLK) begin : S_AXI_RVALID_processing
        if (RESET)
            S_AXI_RVALID <= 1'b0;
        else
            if (S_AXI_ARVALID & S_AXI_ARREADY & ~S_AXI_RVALID)
                S_AXI_RVALID <= 1'b1;
            else 
                if (S_AXI_RVALID & S_AXI_RREADY)
                    S_AXI_RVALID <= 1'b0;

    end 


    always_ff @(posedge CLK) begin : S_AXI_RDATA_processing
        if (RESET)
            S_AXI_RDATA <= '{default:0};
        else
            if (S_AXI_ARVALID & S_AXI_ARREADY & ~S_AXI_RVALID)
                case (S_AXI_ARADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB])
                    'h0     : S_AXI_RDATA <= register[ 0];
                    'h1     : S_AXI_RDATA <= register[ 1];
                    'h2     : S_AXI_RDATA <= register[ 2];
                    'h3     : S_AXI_RDATA <= register[ 3];
                    'h4     : S_AXI_RDATA <= register[ 4];
                    'h5     : S_AXI_RDATA <= register[ 5];
                    'h6     : S_AXI_RDATA <= register[ 6];
                    'h7     : S_AXI_RDATA <= register[ 7];
                    'h8     : S_AXI_RDATA <= register[ 8];
                    'h9     : S_AXI_RDATA <= register[ 9];
                    'hA     : S_AXI_RDATA <= register[10];
                    'hB     : S_AXI_RDATA <= register[11];
                    'hC     : S_AXI_RDATA <= register[12];
                    'hD     : S_AXI_RDATA <= register[13];
                    'hE     : S_AXI_RDATA <= register[14];
                    default : S_AXI_RDATA <= S_AXI_RDATA;
                endcase // S_AXI_ARADDR
    end 



    always_ff @(posedge CLK) begin : S_AXI_RRESP_processing 
        if (RESET) 
            S_AXI_RRESP <= '{default:0};
        else
            if (S_AXI_ARVALID & S_AXI_ARREADY & ~S_AXI_RVALID)
                case (S_AXI_ARADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB])
                    'h0 : S_AXI_RRESP <= '{default:0};
                    'h1 : S_AXI_RRESP <= '{default:0};
                    'h2 : S_AXI_RRESP <= '{default:0};
                    'h3 : S_AXI_RRESP <= '{default:0};
                    'h4 : S_AXI_RRESP <= '{default:0};
                    'h5 : S_AXI_RRESP <= '{default:0};
                    'h6 : S_AXI_RRESP <= '{default:0};
                    'h7 : S_AXI_RRESP <= '{default:0};
                    'h8 : S_AXI_RRESP <= '{default:0};
                    'h9 : S_AXI_RRESP <= '{default:0};
                    'hA : S_AXI_RRESP <= '{default:0};
                    'hB : S_AXI_RRESP <= '{default:0};
                    'hC : S_AXI_RRESP <= '{default:0};
                    'hD : S_AXI_RRESP <= '{default:0};
                    'hE : S_AXI_RRESP <= '{default:0};
                    default : S_AXI_RRESP <= 'b10;
                endcase; // S_AXI_ARADDR
    end                     



    always_ff @(posedge CLK) begin : S_AXI_BRESP_processing
        if (RESET)
            S_AXI_BRESP <= '{default:0};
        else
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY & ~S_AXI_BVALID)
                if (S_AXI_AWADDR >= 0 | S_AXI_AWADDR <= 10 )
                    S_AXI_BRESP <= '{default:0};
                else
                    S_AXI_BRESP <= 'b10;
    end



    /*done*/
    always_ff @(posedge CLK) begin : reg_1_processing
        if (RESET) begin
            register[1] <= '{default:0};
        end else
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY)
                if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h01) begin
                    register[1] <= S_AXI_WDATA[31:0];
                end
    end 



    /*done*/
    always_ff @(posedge CLK) begin : reg_2_processing
        if (RESET) begin
            register[2] <= '{default:0};
        end else
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY)
                if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h02) begin
                    register[2] <= S_AXI_WDATA[31:0];
                end
    end 



    /*done*/
    always_ff @(posedge CLK) begin : reg_3_processing
        if (RESET) begin
            register[3] <= '{default:0};
        end else
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY)
                if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h03) begin
                    register[3] <= S_AXI_WDATA[31:0];
                end
    end 



    /*done*/
    always_ff @(posedge CLK) begin : reg_4_processing
        if (RESET) begin
            register[4] <= '{default:0};
        end else
            if (S_AXI_AWVALID & S_AXI_AWREADY & S_AXI_WVALID & S_AXI_WREADY)
                if (S_AXI_AWADDR[(ADDR_OPT + ADDR_LSB) : ADDR_LSB] == 'h04) begin
                    register[4] <= S_AXI_WDATA[31:0];
                end
    end 



    axi_memory_reader_pkt_functional #(
        .BYTE_WIDTH (BYTE_WIDTH ),
        .ADDR_WIDTH (ADDR_WIDTH ),
        .BURST_LIMIT(BURST_LIMIT)
    ) axi_memory_reader_pkt_functional_inst (
        .CLK             (CLK                            ),
        .RESET           (RESET                          ),
        //internal interface
        .CMD_ADDRESS     (memory_baseaddr[ADDR_WIDTH-1:0]),
        .CMD_SIZE        (memory_size[63:0]              ),
        .CMD_EMPTY       (memory_fifo_empty              ),
        .CMD_RDEN        (memory_fifo_rden               ),
        
        // interface to memory
        .M_AXI_ARADDR    (M_AXI_ARADDR                   ),
        .M_AXI_ARLEN     (M_AXI_ARLEN                    ),
        .M_AXI_ARSIZE    (M_AXI_ARSIZE                   ),
        .M_AXI_ARBURST   (M_AXI_ARBURST                  ),
        .M_AXI_ARVALID   (M_AXI_ARVALID                  ),
        .M_AXI_ARREADY   (M_AXI_ARREADY                  ),
        .M_AXI_RDATA     (M_AXI_RDATA                    ),
        .M_AXI_RRESP     (M_AXI_RRESP                    ),
        .M_AXI_RLAST     (M_AXI_RLAST                    ),
        .M_AXI_RVALID    (M_AXI_RVALID                   ),
        .M_AXI_RREADY    (M_AXI_RREADY                   ),
        // interface to flash
        .M_AXIS_TDATA    (M_AXIS_TDATA                   ),
        .M_AXIS_TKEEP    (M_AXIS_TKEEP                   ),
        .M_AXIS_TVALID   (M_AXIS_TVALID                  ),
        .M_AXIS_TREADY   (M_AXIS_TREADY                  ),
        .M_AXIS_TLAST    (M_AXIS_TLAST                   ),
        // время в тактах
        .ELAPSED_TIME    (elapsed_time                   ),
        .READER_BUSY     (reader_busy                    ),
        .TRANSFERRED_SIZE(transferred_size               ),
        
        .QUERY_COUNT     (query_count                    ),
        .DATA_COUNT      (data_count                     )
    );

    fifo_cmd_sync_xpm #(
        .DATA_WIDTH(CMD_FIFO_WIDTH  ),
        .MEMTYPE   (CMD_FIFO_MEMTYPE),
        .DEPTH     (CMD_FIFO_DEPTH  )
    ) fifo_cmd_sync_xpm_inst (
        .CLK  (CLK                                                           ),
        .RESET(reset_func                                                    ),
        .DIN  ({memory_fifo_baseaddr[ADDR_WIDTH-1:0], memory_fifo_size[63:0]}),
        .WREN (memory_fifo_enable                                            ),
        .FULL (                                                              ),
        .DOUT ({memory_baseaddr[ADDR_WIDTH-1:0], memory_size[63:0]}          ),
        .RDEN (memory_fifo_rden                                              ),
        .EMPTY(memory_fifo_empty                                             )
    );

    always_ff @(posedge CLK) begin : query_fifo_volume_processing 
        if (reset_func) begin 
            query_fifo_volume <= '{default:0};
        end else begin 
            if (memory_fifo_enable) begin 
                if (memory_fifo_rden) begin 
                    query_fifo_volume <= query_fifo_volume;
                end else begin 
                    query_fifo_volume <= query_fifo_volume + 1;
                end 
            end else begin 
                if (memory_fifo_rden) begin 
                    query_fifo_volume <= query_fifo_volume - 1;
                end else begin 
                    query_fifo_volume <= query_fifo_volume;
                end 
            end 
        end 
    end 





    always_ff @(posedge CLK) begin : timer_processing 
        if (timer < (FREQ_HZ-1)) begin 
            timer <= timer + 1;
        end else begin 
            timer <= '{default:0};
        end 
    end 

    always_ff @(posedge CLK) begin : valid_count_processing 
        if (timer < (FREQ_HZ-1)) begin 
            if (M_AXI_RREADY & M_AXI_RVALID) begin 
                valid_count <= valid_count + 1;
            end else begin 
                valid_count <= valid_count;
            end 
        end else begin 
            valid_count <= '{default:0};
        end 
    end 

    always_ff @(posedge CLK) begin : valid_count_reg_processing 
        if (timer < (FREQ_HZ-1)) begin 
            valid_count_reg <= valid_count_reg;
        end else begin 
            if (M_AXI_RREADY & M_AXI_RVALID) begin 
                valid_count_reg <= valid_count + 1;
            end else begin 
                valid_count_reg <= valid_count;
            end 
        end 
    end 
    

endmodule
