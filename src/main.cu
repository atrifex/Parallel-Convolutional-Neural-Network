#include <algorithm>
#include <cassert>
#include <cstddef>
#include <iostream>
#include <numeric>
#include <map>
#include <sys/time.h>
#include <valarray>

#include <hdf5.h>

#include "range.hpp"
#include "utils.hpp"

#define NUM_ROWS 28
#define NUM_COLS 28
#define NUM_CHANNELS 1
#define NUM_DIGITS 10

// Same as block dimension
#define TILE_WIDTH 16

static int FLAGS_batch_size = 10000;
static std::string FLAGS_testdata{};
static std::string FLAGS_model{};

// Data and reference data dimensions
static int xdims[] = {FLAGS_batch_size, NUM_ROWS, NUM_COLS, NUM_CHANNELS};
static int rdims[] = {FLAGS_batch_size, NUM_DIGITS};

// Model dimensions
static int conv1dims[] = {5, 5, 1, 32};
static int conv2dims[] = {5, 5, 32, 64};
static int fc1dims[]   = {1024, 128};
static int fc2dims[]   = {128, 10};

static int loadData(float *x, float *y) {
    // Open the data file
    const auto file_id =
        H5Fopen(FLAGS_testdata.c_str(), H5F_ACC_RDWR, H5P_DEFAULT);

    // Open the dataset x and y
    const auto x_id = H5Dopen2(file_id, "/x", H5P_DEFAULT);
    const auto y_id = H5Dopen2(file_id, "/y", H5P_DEFAULT);

    // Get the dataset x dimensions
    const auto xspace = H5Dget_space(x_id);
    const auto xndims = H5Sget_simple_extent_ndims(xspace);
    assert(xndims == 4);

    hsize_t input_dims[xndims];
    H5Sget_simple_extent_dims(xspace, input_dims, NULL);
    if (input_dims[0] != FLAGS_batch_size) {
        std::cout << "data size does not match batch size specified!\n";
        return 1; // return error
    }
    std::cout << "input dimensions = " << input_dims[0] << " x " << input_dims[1]
              << " x " << input_dims[2] << " x " << input_dims[3] << "\n";

    // Read the dataset x and y
    check_success(
        H5Dread(x_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, x));
    check_success(
        H5Dread(y_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, y));

    // Close the dataset x and y
    check_success(H5Dclose(x_id));
    check_success(H5Dclose(y_id));

    // Close the file
    check_success(H5Fclose(file_id));

    // return success
    return 0;
}

static void loadModel(float *conv1, float *conv2, float *fc1, float *fc2) {
    // Open the model file
    const auto file_id = H5Fopen(FLAGS_model.c_str(), H5F_ACC_RDWR, H5P_DEFAULT);

    // Open the dataset
    const auto conv1_id = H5Dopen2(file_id, "/conv1", H5P_DEFAULT);
    const auto conv2_id = H5Dopen2(file_id, "/conv2", H5P_DEFAULT);
    const auto fc1_id   = H5Dopen2(file_id, "/fc1", H5P_DEFAULT);
    const auto fc2_id   = H5Dopen2(file_id, "/fc2", H5P_DEFAULT);

    // Read the dataset
    check_success(H5Dread(conv1_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL,
                          H5P_DEFAULT, conv1));
    check_success(H5Dread(conv2_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL,
                          H5P_DEFAULT, conv2));
    check_success(
        H5Dread(fc1_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, fc1));
    check_success(
        H5Dread(fc2_id, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, fc2));

    // Close the dataset x and y
    check_success(H5Dclose(conv1_id));
    check_success(H5Dclose(conv2_id));
    check_success(H5Dclose(fc1_id));
    check_success(H5Dclose(fc2_id));

    // Close the file
    check_success(H5Fclose(file_id));
}

// Kernel to compute C = A * B
__global__ void matrixMultiplyShared(float *A, float *B, float *C,
                                     int numARows, int numAColumns,
                                     int numBRows, int numBColumns,
                                     int numCRows, int numCColumns) {

  	// Declare shared memory tiles Ads and Bds
    __shared__ float Ads[TILE_WIDTH][TILE_WIDTH];
    __shared__ float Bds[TILE_WIDTH][TILE_WIDTH];

  	// Get row and column of the output element this thread is working on
		int CRow = blockIdx.y*blockDim.y + threadIdx.y;
		int CCol = blockIdx.x*blockDim.x + threadIdx.x;

  	// Idea: in each "phase," have threads collaboratively load subsets of A and B elements
	  // into the shared memory before they individually use these elements in dot product calculation.
  	// These A and B subsets are referred to as "tiles"; they are the same size as the block dimensions
  	// (16 in our case).  We need enough phases such that the tiles span the entire image- we'll also
  	// need checks to ensure our algorithm works in the case of output dimensions that are not a multiple of
  	// the tile width.

  	int phase; // loop variable for phases
  	int dot; // loop variable for dot product in each phase
  	float Cval = 0.0f; // Holds accumulating value of output element


      // Including a +1 accounts for the case in which dimensions are not a multiple of TILE_WIDTH
      // Why can't we use ceil??????
      for(phase = 0; phase < (numAColumns-1)/TILE_WIDTH + 1; phase++)
      {
        // Don't try to load nonexistent elements
        if((CRow < numCRows) && ((threadIdx.x + phase*TILE_WIDTH) < numAColumns))
        {
          // Each thread loads an element into shared memory
          Ads[threadIdx.y][threadIdx.x] = A[CRow*numAColumns + threadIdx.x + phase*TILE_WIDTH];
        }

        // Don't try to load nonexistent elements
        // Note: A and B have to be checked separately as they could have wildly different dimensions
        if((CCol < numCColumns) && ((threadIdx.y + phase*TILE_WIDTH) < numBRows))
        {
          // Each thread loads an element into shared memory
          Bds[threadIdx.y][threadIdx.x] = B[(threadIdx.y + phase*TILE_WIDTH)*numBColumns + CCol];
        }

        __syncthreads(); // Necessary to ensure all threads have loaded their data before proceeding with computation

        for(dot = 0; dot < TILE_WIDTH; dot++) // Perform the dot product operation for current tile
        {
          // Verify that the tile elements don't step outside the bounds of our actual input matrices.
          // Necessary when numAColumns % TILE_WIDTH != 0
          if(((dot + phase*TILE_WIDTH) < numAColumns) && ((dot + phase*TILE_WIDTH) < numBRows))
             Cval += Ads[threadIdx.y][dot]*Bds[dot][threadIdx.x];
        }

        __syncthreads(); // Necessary to ensure all threads have finished computation before overwriting shared memory.
      }

      // Check that the thread is mapped to a valid element
      // Note: this cannot be performed above because threads that point outside the bounds of the output
      // matrix are still needed to load tiles into shared memory.
      if((CRow < numCRows) && (CCol < numCColumns))
      {
        C[CRow*numCColumns + CCol] = (Cval < 0.0f) ? 0.0f : Cval;
      }
}

// Parallel implementation of the filter unroll
__global__ void unrollFilters(int C, int M, int K, float * W, float * W_unroll)
{
  int p, q, c, m;

  m = threadIdx.x;
  c = blockIdx.x;

  if(c < C && m < M)
  {
    for(p = 0; p < K; p++)
    {
      for(q = 0; q < K; q++)
      {
        W_unroll[m*C*K*K + c*K*K + p*K + q] = W[p*K*C*M + q*C*M + c*M + m]; // Should get coalesced read access!
      }
    }
  }
}

// Parallel implementation of the output reroll
__global__ void rerollOutput(int M, int N, int H_out, int W_out, float * Y_unrolled, float * Y)
{
  int m, n, h, w;

  m = threadIdx.x;
  n = blockIdx.x;

  if(m < M && n < N)
  {
    for(h = 0; h < H_out; h++)
    {
      for(w = 0; w < W_out; w++)
      {
        Y[((n * H_out + h) * W_out + w) *M + m] = Y_unrolled[n*M*H_out*W_out + m*H_out*W_out + h*W_out + w];
      }
    }
  }
}

// Sequential input unroll implementation
void unroll(int C, int H, int W, int K, int n, float* X, float* X_unroll, int xdims[4])
{
  int c, h, w, p, q, w_base, w_unroll, h_unroll, x_index;
  int H_out = H - K + 1;
  int W_out = W - K + 1;
  int W_unroll = C * K * K;
  int H_unroll = H_out * W_out;

  for(c = 0; c < C; c++) // input map index
  {
    w_base = c * (K*K);
    for(p = 0; p < K; p++)
    {
      for(q = 0; q < K; q++)
      {
        for(h = 0; h < H_out; h++)
        {
          for(w = 0; w < W_out; w ++)
          {
            w_unroll = w_base + p * K + q;
            h_unroll = h * W_out + w;
            x_index = n*H*W*C + (h+p)*W*C + (w+q)*C + c;

            X_unroll[w_unroll*H_unroll + h_unroll] = X[x_index];
          }
        }
      }
    }
  }
}

void convLayer_forward(int N, int M, int C, int H, int W, int K, float* X, float* Mask, float* Y, int xdims[4], const int ydims[4])
{
  int W_out = W - K + 1;
  int H_out = H - K + 1;
  int W_unroll = C * K * K;
  int H_unroll = H_out * W_out;
  float* X_unrolled = (float*)malloc(W_unroll * H_unroll * sizeof(float));
  float * device_X_unrolled, * device_W, * device_W_unrolled, * device_Y, * device_Y_unrolled;

  //  Allocate device memory and dim3's for filter unrolling
  check_success(cudaMalloc((void**)&device_W_unrolled, M*C*K*K * sizeof(float)));
  check_success(cudaMalloc((void**)&device_W, M*C*K*K * sizeof(float)));
  dim3 blockDimension1(M, 1, 1);
  dim3 gridDimension1(C, 1, 1);

  // Copy memory and aunch kernel to unroll the filter
  check_success(cudaMemcpy(device_W, Mask, M*C*K*K * sizeof(float), cudaMemcpyHostToDevice));

  unrollFilters<<<gridDimension1, blockDimension1>>>(C, M, K, device_W, device_W_unrolled);
  cudaDeviceSynchronize();

  // Next, allocate device memory for input unrolling
  check_success(cudaMalloc((void**)&device_X_unrolled, W_unroll * H_unroll * sizeof(float)));
  check_success(cudaMalloc((void**)&device_Y_unrolled,  M*N*W_out*H_out* sizeof(float)));

  // Initialize the grid and block dimensions
  dim3 blockDimension2(TILE_WIDTH, TILE_WIDTH, 1);
  dim3 gridDimension2(ceil((1.0*H_unroll)/TILE_WIDTH), ceil((1.0*M)/TILE_WIDTH), 1);

  for (int n = 0; n < N; n++)
  {
    unroll(C, H, W, K, n, X, X_unrolled, xdims);
    //gemm(X_unroll_height, M, W_unroll, X_unrolled, W, Y[n]);

    check_success(cudaMemcpy(device_X_unrolled, X_unrolled, W_unroll * H_unroll * sizeof(float), cudaMemcpyHostToDevice));

    matrixMultiplyShared<<<gridDimension2, blockDimension2>>>(device_W_unrolled, device_X_unrolled, &(device_Y_unrolled[n*ydims[1]*ydims[2]*ydims[3]]),
      M, C*K*K, W_unroll, H_unroll, M, H_unroll);

    cudaDeviceSynchronize();

  }

  // Now "re-roll" the output Y
  check_success(cudaMalloc((void**)&device_Y, M*N*W_out*H_out* sizeof(float)));
  dim3 blockDimension3(M, 1, 1);
  dim3 gridDimension3(N, 1, 1);

  rerollOutput<<<gridDimension3, blockDimension3>>>(M, N, H_out, W_out, device_Y_unrolled, device_Y);
  cudaDeviceSynchronize();

  // Copy memory back to host
  check_success(cudaMemcpy(Y, device_Y, M*N*W_out*H_out* sizeof(float), cudaMemcpyDeviceToHost));

  // Free memory
  free(X_unrolled);
  cudaFree(device_X_unrolled);
  cudaFree(device_W_unrolled);
  cudaFree(device_Y_unrolled);
  cudaFree(device_W);
  cudaFree(device_Y);
}

// CUDA kernel for forward convolution path

/* __global__ void conv_forward_kernel(float *X, float *W, float *Y, int xdims[4], int wdims[4], int ydims[4])
 * Local Variables:
 *      n = sample index
 *      m = output map index
 *      w = column index within an output map
 *      h = row index within an output map
 *      p = row index within a mask
 *      q = column index within a mask
 *      c = input map/channel index
 */
__global__ void conv_forward_kernel(float *X, float *W, float *Y, int xdims[4], int wdims[4], int ydims[4])
{
    int n, m, h0, w0, h_base, w_base, h, w;

    int X_tile_width = TILE_WIDTH + wdims[0]-1;
    extern __shared__ float shmem[];
    float* X_shared = &shmem[0];
    float* W_shared = &shmem[X_tile_width * X_tile_width];

    n = blockIdx.x;
    m = blockIdx.y;

    h0 = threadIdx.y;
    w0 = threadIdx.x;
    h_base = (blockIdx.z / ((ydims[2]-1)/TILE_WIDTH + 1))*TILE_WIDTH;
    w_base = (blockIdx.z % ((ydims[1]-1)/TILE_WIDTH + 1))*TILE_WIDTH;
    h = h_base + h0;
    w = w_base + w0;

    float acc = 0.0f;

    // sum over all input channels
    for (int c = 0; c < wdims[2]  ; c++)
    {
        // load weights for W [m, c,..], h0 and w0 used as shorthand for threadIdx.x and threadIdx.y
        int woffset = h0*wdims[1]*wdims[2]*wdims[3] + w0*wdims[2]*wdims[3] + c*wdims[3] + m;
        if (( h0 < wdims[0]) && ( w0 < wdims[1])) W_shared[h0*wdims[1] + w0] = W[woffset];

        __syncthreads();

        // load tile from X[n, c,...] into shared memory
        for (int i = h; i < h_base + X_tile_width; i += TILE_WIDTH)
        {
            for (int j = w; j < w_base + X_tile_width; j += TILE_WIDTH)
            {
                int xoffset = n*xdims[1]*xdims[2]*xdims[3] + i*xdims[2]*xdims[3] + j*xdims[3] + c;
                int x_shared_offset = X_tile_width*(i - h_base) + (j - w_base);
                X_shared[x_shared_offset] = X[xoffset];
            }
        }

        __syncthreads();

        for (int p = 0; p < wdims[0]; p++)
        {
            for (int q = 0; q < wdims[1]; q++)
            {
                int x_shared_offset = X_tile_width*(h0+p) + (w0+q);
                int w_shared_offset = wdims[1]*p + q;
                acc = acc + X_shared[x_shared_offset] * W_shared[w_shared_offset];
            }
        }

        __syncthreads();
    }

    int yoffset = ((n * ydims[1] + h) * ydims[2] + w) * ydims[3] + m;

    if(w < ydims[2] && h < ydims[1])
        Y[yoffset] = (acc < 0.0f) ? 0.0f : acc;
}

// CUDA kernel for average pool
__global__ void average_pool_kernel(float *X, float *Y, int xdims[4], int ydims[4], int pool_size) {

    int n, m, h, w;
    n = blockIdx.x;
    m = blockIdx.y;

    h = (blockIdx.z / ((ydims[2]-1)/TILE_WIDTH + 1))*TILE_WIDTH + threadIdx.y;
    w = (blockIdx.z % ((ydims[1]-1)/TILE_WIDTH + 1))*TILE_WIDTH + threadIdx.x;

    int i = n;

    if(w < ydims[2] && h < ydims[1]){
        float acc = 0.0f;
        for (int p = 0; p < pool_size; p++) {
            for (int q = 0; q < pool_size; q++) {
                int xoffset = i * xdims[1] * xdims[2] * xdims[3] + (pool_size * h + p) * xdims[2] * xdims[3] + (pool_size * w + q) * xdims[3] + m;
                acc += X[xoffset] / (1.0f * pool_size * pool_size);
            }
        }
        int yoffset = ((i * ydims[1] + h) * ydims[2] + w) * ydims[3] + m;
        Y[yoffset] = acc;
    }
}

static void fully_forward(const float *X, const int xdims[2], float *W,

                          const int wdims[2], float *Y, const int ydims[2]) {
    for (const auto i : range(0, xdims[0])) {
        for (const auto j : range(0, wdims[1])) {
            float sum = 0;
            for (const auto k : range(0, xdims[1])) {
                sum += X[i * xdims[1] + k] * W[k * wdims[1] + j];
            }
            Y[i * wdims[1] + j] = (sum < 0.0f) ? 0.0f : sum;
        }
    }
}

// Choose the guess with largest score
static void argmax(const float *X, const int xdims[2], int *Y) {
    for (const auto i : range(0, xdims[0])) {
        auto max_idx = 0;
        auto max     = X[i * xdims[1]];
        for (const auto j : range(0, xdims[1])) {
            const auto elem = X[(i * xdims[1]) + j];
            if (elem > max) {
                max_idx = j;
                max     = elem;
            }
        }
        Y[i] = max_idx;
    }
}

// Forward operation for the CNN, a combination of conv layer + average pooling
// + relu
void forward_operation(float *x, float *conv1, float *conv2, float *fc1,
                       float *fc2, int *out) {

    // conv layer 1 vars
    const int adims[] = {xdims[0], (xdims[1] - conv1dims[0] + 1),
                         (xdims[2] - conv1dims[1] + 1), conv1dims[3]};
    auto a = zeros<float>(adims);
    float * conv1Output = (float*)malloc(adims[0]*adims[1]*adims[2]*adims[3]*xdims[3]*sizeof(float));

    // avg pool 1 vars
    const int pool_size = 2;
    const int bdims[]   = {adims[0], adims[1] / pool_size, adims[2] / pool_size,
                           adims[3]};
    auto b = zeros<float>(bdims);

    // conv layer 2 vars
    const int cdims[] = {bdims[0], (bdims[1] - conv2dims[0] + 1),
                         (bdims[2] - conv2dims[1] + 1), conv2dims[3]};
    auto c = zeros<float>(cdims);
    float * conv2Output = (float*)malloc(cdims[0]*cdims[1]*cdims[2]*cdims[3]*sizeof(float));

    // avg pool 2 vars
    const int ddims[] = {cdims[0], cdims[1] / pool_size, cdims[2] / pool_size,
                         cdims[3]};
    auto d = zeros<float>(ddims);
    auto pool2Output = zeros<float>(ddims);

    // fully connected layer 1 vars
    const int ddims2[] = {ddims[0], ddims[1] * ddims[2] * ddims[3]};
    const int edims[] = {ddims[0], fc1dims[1]};
    auto e = zeros<float>(edims);

    // fully connected layer 2 vars
    const int fdims[] = {edims[0], fc2dims[1]};
    auto f = zeros<float>(fdims);

    // CUDA device vars
    int * deviceIndims, * deviceMaskdims, * deviceOutdims;               // logistical vars
    float * deviceInputConv1, * deviceMaskConv1, * deviceOutputConv1;    // conv 1 vars
    float * deviceInputPool1, * deviceOutputPool1;                       // pool 1 vars
    float * deviceInputConv2, * deviceMaskConv2, * deviceOutputConv2;    // conv 2 vars
    float * deviceInputPool2, * deviceOutputPool2;                       // pool 2 vars
    float * deviceInputFullyForward1, * deviceOutputFullyForward1;       // fully connected 1 vars
    float * deviceInputFullyForward2, * deviceOutputFullyForward2;       // fully connected 2 vars

    // allocate memory for device data dims
    check_success(cudaMalloc((void**)&deviceIndims, 4*sizeof(int)));
    check_success(cudaMalloc((void**)&deviceMaskdims, 4*sizeof(int)));
    check_success(cudaMalloc((void**)&deviceOutdims, 4*sizeof(int)));

    /*********************************************** CONV 1 Layer ************************************************/

    // Done using unrolling and matrix-matrix multiplication
    convLayer_forward(xdims[0], conv1dims[3], conv1dims[2], xdims[1], xdims[2], conv1dims[0], x, conv1, conv1Output, xdims, adims);

    check_success(cudaMalloc((void**)&deviceInputPool1, adims[0]*adims[1]*adims[2]*adims[3]*xdims[3]*sizeof(float)));

    check_success(cudaMemcpy(deviceInputPool1, conv1Output, adims[0]*adims[1]*adims[2]*adims[3]*xdims[3]*sizeof(float), cudaMemcpyHostToDevice));

    /*********************************************** AVG POOL 1 Layer ************************************************/
    // allocate memory for device pool 1 calculation
    check_success(cudaMalloc((void**)&deviceOutputPool1, bdims[0]*bdims[1]*bdims[2]*bdims[3]*xdims[3]*sizeof(float)));

    // copy data dims to device
    check_success(cudaMemcpy(deviceIndims, adims, 4*sizeof(int),cudaMemcpyHostToDevice));
    check_success(cudaMemcpy(deviceOutdims, bdims, 4*sizeof(int),cudaMemcpyHostToDevice));

    // kernel dims
    int N = adims[0];
    int M = conv1dims[3];
    int Z = ((bdims[2]-1)/TILE_WIDTH+1)*((bdims[1]-1)/TILE_WIDTH+1);//adims[2]*adims[1];
    dim3 blockDimPool1(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDimPool1(N, M, Z);

    // avg pool 1 launch
    average_pool_kernel<<<gridDimPool1, blockDimPool1>>>(deviceInputPool1, deviceOutputPool1, deviceIndims, deviceOutdims, pool_size);
    cudaDeviceSynchronize();

    check_success(cudaMemcpy(b, deviceOutputPool1, bdims[0]*bdims[1]*bdims[2]*bdims[3]*sizeof(float), cudaMemcpyDeviceToHost));

    // avg pool memory freed
    cudaFree(deviceInputPool1);
    cudaFree(deviceOutputPool1);

    /*********************************************** CONV 2 Layer ************************************************/

    // Done using unrolling and matrix-matrix multiplication
    convLayer_forward(xdims[0], conv2dims[3], conv2dims[2], bdims[1], bdims[2], conv2dims[0], b, conv2, conv2Output, (int*)bdims, cdims);

    check_success(cudaMalloc((void**)&deviceInputPool2, cdims[0]*cdims[1]*cdims[2]*cdims[3]*sizeof(float)));

    check_success(cudaMemcpy(deviceInputPool2, conv2Output, cdims[0]*cdims[1]*cdims[2]*cdims[3]*sizeof(float), cudaMemcpyHostToDevice));

    /*
    // conv layer 2 setup
    check_success(cudaMalloc((void**)&deviceMaskConv2, conv2dims[0]*conv2dims[1]*conv2dims[2]*conv2dims[3]*xdims[3]*sizeof(float)));
    check_success(cudaMalloc((void**)&deviceOutputConv2, cdims[0]*cdims[1]*cdims[2]*cdims[3]*xdims[3]*sizeof(float)));

    // copy data to device
    check_success(cudaMemcpy(deviceMaskConv2, conv2, conv2dims[0]*conv2dims[1]*conv2dims[2]*conv2dims[3]*xdims[3]*sizeof(float),cudaMemcpyHostToDevice));

    // copy data dims to device
    check_success(cudaMemcpy(deviceIndims, bdims, 4*sizeof(int),cudaMemcpyHostToDevice));
    check_success(cudaMemcpy(deviceMaskdims, conv2dims, 4*sizeof(int),cudaMemcpyHostToDevice));
    check_success(cudaMemcpy(deviceOutdims, cdims, 4*sizeof(int),cudaMemcpyHostToDevice));

    // kernel dims
    N = bdims[0];
    M = conv2dims[3];
    Z = ((cdims[2]-1)/TILE_WIDTH+1)*((cdims[1]-1)/TILE_WIDTH+1);
    dim3 blockDimConv2(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDimConv2(N, M, Z);

    unsigned int shmem_size_2 = sizeof(float)*((TILE_WIDTH + conv2dims[1] - 1)*(TILE_WIDTH + conv2dims[0] - 1) + conv2dims[0]*conv2dims[1]);

    // conv layer 2
    conv_forward_kernel<<<gridDimConv2, blockDimConv2, shmem_size_2>>>(deviceInputConv2, deviceMaskConv2, deviceOutputConv2, deviceIndims, deviceMaskdims, deviceOutdims);
    cudaDeviceSynchronize();

    // simply use the device output data as input for the next kernel launch
    deviceInputPool2 = deviceOutputConv2;

    // freeing device memory for conv 2 layer
    cudaFree(deviceInputConv2);
    cudaFree(deviceMaskConv2);
    */

    /*********************************************** AVG POOL 2 Layer ************************************************/
    // allocate memory for device pool 2 calculation
    check_success(cudaMalloc((void**)&deviceOutputPool2, ddims[0]*ddims[1]*ddims[2]*ddims[3]*xdims[3]*sizeof(float)));

    // copy data dims to device
    check_success(cudaMemcpy(deviceIndims, cdims, 4*sizeof(int),cudaMemcpyHostToDevice));
    check_success(cudaMemcpy(deviceOutdims, ddims, 4*sizeof(int),cudaMemcpyHostToDevice));

    // kernel dims
    N = cdims[0];
    M = conv2dims[3];
    Z = ((ddims[2]-1)/TILE_WIDTH+1)*((ddims[1]-1)/TILE_WIDTH+1);//adims[2]*adims[1];
    dim3 blockDimPool2(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDimPool2(N, M, Z);

    // Second average pool kernel launch
    average_pool_kernel<<<gridDimPool2, blockDimPool2>>>(deviceInputPool2, deviceOutputPool2, deviceIndims, deviceOutdims, pool_size);
    cudaDeviceSynchronize();

    // copy output data back from device
    check_success(cudaMemcpy(pool2Output, deviceOutputPool2, ddims[0]*ddims[1]*ddims[2]*ddims[3]*xdims[3]*sizeof(float), cudaMemcpyDeviceToHost));

    // avg pool memory freed
    cudaFree(deviceInputPool2);
    cudaFree(deviceOutputPool2);

    /*********************************************** FULLY CONNECTED 1 Layer ************************************************/
    fully_forward(pool2Output, ddims2, fc1, fc1dims, e, edims);

    /*********************************************** FULLY CONNECTED 2 Layer ************************************************/
    fully_forward(e, edims, fc2, fc2dims, f, fdims);

    /*********************************************** GAUSSIAN Layer ************************************************/
    argmax(f, fdims, out);

    // freeing host buffers
    delete[] a;
    delete[] b;
    delete[] c;
    delete[] d;
    delete[] e;
    delete[] f;
    delete[] pool2Output;
    delete[] conv1Output;
    delete[] conv2Output;

    // freeing device memory for dimensional data
    cudaFree(deviceIndims);
    cudaFree(deviceMaskdims);
    cudaFree(deviceOutdims);
}

int main(int argc, char **argv) {

    if (argc != 3 && argc != 4) {
        std::cerr << "\n"
                  << "This program performs the forward opertion step for "
            "Convolutional Neural Network(CNN).  "
            "Sample usage: \n"
                  << argv[0]
                  << " [../data/test10.hdf5] [../data/model.hdf5] [10]\n";
        return -1;
    }
    FLAGS_testdata = std::string(argv[1]);
    FLAGS_model    = std::string(argv[2]);
    if (argc == 3) {
        const std::map<std::string, int> default_batch_sizes{
            {"../data/test2.hdf5", 2},
            {"../data/test10.hdf5", 10},
            {"../data/test100.hdf5", 100},
            {"../data/testfull.hdf5", 10000}};
        const auto batch_size_in_map = default_batch_sizes.find(FLAGS_testdata);
        if (batch_size_in_map == default_batch_sizes.end()) {
            std::cerr << "\nERROR:: Unrecognized file " << FLAGS_testdata << " batch_size must be specified.\n";
            return -1;
        }
        FLAGS_batch_size = batch_size_in_map->second;
    } else if (argc == 4) {
        FLAGS_batch_size = atoi(argv[3]);
    }
    xdims[0] = FLAGS_batch_size;
    rdims[0] = FLAGS_batch_size;

    // Load data into x and y
    float *x = allocate<float>(xdims);
    float *y = allocate<float>(rdims);
    loadData(x, y);

    // Load model
    float *conv1 = allocate<float>(conv1dims);
    float *conv2 = allocate<float>(conv2dims);
    float *fc1   = allocate<float>(fc1dims);
    float *fc2   = allocate<float>(fc2dims);
    loadModel(conv1, conv2, fc1, fc2);

    // Perform foward opertion
    int *out = zeros<int>(FLAGS_batch_size);

    // get start time
    const auto start = now();

    forward_operation(x, conv1, conv2, fc1, fc2, out);

    // get end time
    const auto end = now();

    // get elapsed time in milliseconds
    const auto elapsed =
        std::chrono::duration<double, std::milli>(end - start).count();

    // Get reference
    int *ref = zeros<int>(FLAGS_batch_size);
    argmax(y, rdims, ref);

    // Calculate correctness
    int num_correct = 0;
    for (const auto i : range(0, FLAGS_batch_size)) {
        if (out[i] == ref[i]) {
            num_correct++;
        }
    }
    std::cout << "Done with " << FLAGS_batch_size << " queries in "
              << "elapsed = " << elapsed << " milliseconds. Correctness: "
              << static_cast<float>(num_correct) / FLAGS_batch_size << "\n";

    delete[] x;
    delete[] y;
    delete[] conv1;
    delete[] conv2;
    delete[] fc1;
    delete[] fc2;
    delete[] out;
    delete[] ref;

    return 0;
}
