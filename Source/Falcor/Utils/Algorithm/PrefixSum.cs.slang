/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

/** Parallel prefix sum computed in place using exclusive scan.

    The host sets these defines:
    GROUP_SIZE <N>      Thread group size, must be a power-of-two <= 1024.

    The implementation is based on G. Blelloch, "Vector Models for Data-Parallel Computing", MIT Press, 1990.
    See CUDA code: http://http.developer.nvidia.com/GPUGems3/gpugems3_ch39.html
    See also: http://www.umiacs.umd.edu/~ramani/cmsc828e_gpusci/ScanTalk.pdf
*/

cbuffer CB
{
    uint gNumGroups;        ///< Number of groups we'll process, each group is 2N elements.
    uint gTotalNumElems;    ///< Total number of elements. This does not have to be a multiple of the group size.
    uint gIter;             ///< The current iteration, if there are more elements than 2 * GROUP_SIZE * GROUP_SIZE, the prefix sum will be split into multiple iterations.
};

RWByteAddressBuffer gData;                      ///< Data buffer.
RWByteAddressBuffer gPrefixGroupSums;           ///< One uint per group, each holds the sum of all elements in the group and to the left.
RWByteAddressBuffer gTotalSum;                  ///< One uint, holds the total sum of a prefix sum iteration.
ByteAddressBuffer gPrevTotalSum;                ///< One uint, holds the previous total sum of the previous prefix sum iteration.

groupshared uint gSharedData[2 * GROUP_SIZE];   ///< Temporary working buffer in shared memory for 2N elements.


/** Parallel prefix sum in shared memory over consecutive groups of 2N elements,
    where N is the thread group size.
    This shader reads from gData and writes one uint32_t per group to gPrefixGroupSums.
*/
[numthreads(GROUP_SIZE, 1, 1)]
void groupScan(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    const uint thid = groupThreadID.x;      // Local thread ID in the range 0..N-1.
    const uint groupIdx = groupID.x;        // Group index where each group represents 2N elements.

    // Load data for group into shared memory. Each thread loads two elements.
    // Interleaved load at consecutive addresses can lead to 2x bank conflicts.
    // It's probably better to load one element into each half of the array as we do here.
    // We pad the data with zeros in shared memory if actual #elements is less than working set.

    const uint prevSum = gPrevTotalSum.Load(0);
    const uint idx = 2 * GROUP_SIZE * GROUP_SIZE * gIter + groupIdx * (2 * GROUP_SIZE) + thid;
    uint prevData1 = (idx < gTotalNumElems ? gData.Load(idx * 4) : 0);
    uint prevData2 = ((idx + GROUP_SIZE) < gTotalNumElems ? gData.Load((idx + GROUP_SIZE) * 4) : 0);
    gSharedData[thid] = prevData1;
    gSharedData[thid + GROUP_SIZE] = prevData2;

    // Reducation phase.
    // We do log2(N)+1 iterations for d = 2^(N), 2^(N-1), .., 2, 1.
    uint offset = 1;
    for (uint d = GROUP_SIZE; d > 0; d >>= 1)
    {
        GroupMemoryBarrierWithGroupSync();

        if (thid < d)
        {
            uint ai = offset * (2 * thid + 1) - 1;
            uint bi = ai + offset;

            gSharedData[bi] += gSharedData[ai];
        }
        offset <<= 1;    // offset = 1, 2, ... N
    }

    GroupMemoryBarrierWithGroupSync();

    // Compute prefix sum over groups.
    // Since groups run out-of-order, we use atomics to add our group's sum to all relevent group sums.
    // This can get slow for large inputs, but for moderate sized inputs (tens to hundreds of groups) it's probably still very fast.
    // The alternative is to run an extra shader pass computing the prefix sum over the groups.
    if (thid >= groupIdx && thid < gNumGroups)
    {
        uint sum = gSharedData[2 * GROUP_SIZE - 1];
        gPrefixGroupSums.InterlockedAdd(thid * 4, sum);

        // One thread per group also adds the group sum to the total sum.
        if (thid == gNumGroups - 1)
        {
            gTotalSum.InterlockedAdd(0, sum);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    // Zero out top element, this is required for down-sweep phase to work correctly.
    // Only one thread in each group does this.

    // Down-sweep phase.
    // We do log2(N)+1 iterations for d = 1, 2, 4, ..., N.
    for (uint d = 1; d <= GROUP_SIZE; d *= 2)
    {
        offset >>= 1; // offset = N, N/2, ..., 1

        GroupMemoryBarrierWithGroupSync();

        if (thid < d - 1)
        {
            uint ai = offset * (2 * thid + 2) - 1;
            uint bi = ai + offset;

            gSharedData[bi] += gSharedData[ai];
        }
    }

    GroupMemoryBarrierWithGroupSync();

    // Write results to memory and add prev sum. Lower half first then upper half.
    // uint leftGroupSum;
    // if (groupIdx == 0) {
    //     leftGroupSum = 0;
    // } else {
    //     leftGroupSum = gPrefixGroupSums.Load((groupIdx - 1)*4);
    // }
    // if (idx < gTotalNumElems) gData.Store(idx * 4, gSharedData[thid] + prevSum + leftGroupSum);
    // if ((idx + GROUP_SIZE) < gTotalNumElems) gData.Store((idx + GROUP_SIZE) * 4, gSharedData[thid + GROUP_SIZE] + prevSum + leftGroupSum);
    if (idx < gTotalNumElems) {
        uint addr = idx * 4;
        gData.Store(addr, gSharedData[thid] + prevSum - prevData1);
    }
    if ((idx + GROUP_SIZE) < gTotalNumElems) {
        uint addr = (idx + GROUP_SIZE) * 4;
        gData.Store(addr, gSharedData[thid + GROUP_SIZE] + prevSum - prevData2);
    }
}

/** Pass for finalizing a prefix sum computed over multiple thread groups.
    Each thread here operates on one element of the data buffer.
    Note that we're skipping the first N elements as those don't need to be added
    (their group's prefix sum is zero).
*/
[numthreads(GROUP_SIZE, 1, 1)]
void finalizeGroups(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    const uint thid = groupThreadID.x;      // Local thread ID in the range 0..N-1.
    const uint groupIdx = groupID.x;        // Group index where each group represents N elements (skipping first 2N elements).

    uint sum = gPrefixGroupSums.Load((groupIdx >> 1) * 4);
    uint globalIdx = (groupIdx * GROUP_SIZE) + thid + 2 * GROUP_SIZE * (1 + GROUP_SIZE * gIter);  // Skip first 2N elements.

    if (globalIdx < gTotalNumElems)
    {
        uint addr = globalIdx * 4;
        uint elem = gData.Load(addr);
        gData.Store(addr, elem + sum);
    }
}
