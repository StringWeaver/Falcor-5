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
    uint gIter;             ///< The current iteration, if there are more elements than 4 * GROUP_SIZE * GROUP_SIZE, the prefix sum will be split into multiple iterations.
};

RWByteAddressBuffer gData;                      ///< Data buffer.
RWByteAddressBuffer gPrefixGroupSums;           ///< One uint per group, each holds the sum of all elements in the group and to the left.
RWByteAddressBuffer gTotalSum;                  ///< One uint, holds the total sum of a prefix sum iteration.

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

    const uint idx = 4 * GROUP_SIZE * GROUP_SIZE * gIter + groupIdx * (2 * GROUP_SIZE) + thid;
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

    uint sum = gSharedData[2 * GROUP_SIZE - 1];
    if (thid == GROUP_SIZE - 1)
    {
        gPrefixGroupSums.Store(groupIdx * 4, sum);
    }

    // Write results to memory and add prev sum. Lower half first then upper half.
    if (idx < gTotalNumElems) {
        uint addr = idx * 4;
        gData.Store(addr, gSharedData[thid]  - prevData1);
    }
    if ((idx + GROUP_SIZE) < gTotalNumElems) {
        uint addr = (idx + GROUP_SIZE) * 4;
        gData.Store(addr, gSharedData[thid + GROUP_SIZE]  - prevData2);
    }
}

[numthreads(GROUP_SIZE, 1, 1)]
void interGroupSum(uint3 groupID: SV_GroupID, uint3 groupThreadID: SV_GroupThreadID)
{
    const uint thid = groupThreadID.x; // Local thread ID in the range 0..N-1.
    const uint groupIdx = groupID.x;   // Group index where each group represents 2N elements.
    
    uint leftData, rightData;
    if (thid < gNumGroups) {
        leftData = gPrefixGroupSums.Load(thid * 4);
    } else {
        leftData = 0;
    }
    if (thid + GROUP_SIZE < gNumGroups) {
        rightData = gPrefixGroupSums.Load((thid + GROUP_SIZE) * 4);
    } else {
        rightData = 0;
    }
    gSharedData[thid] = leftData;
    gSharedData[thid + GROUP_SIZE] = rightData;
    const uint prevIterSum = gTotalSum.Load(0);
    // Reducation phase.
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
        offset <<= 1; // offset = 1, 2, ... N
    }

    // Down-sweep phase.
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
    if (thid < gNumGroups) {
        uint addr = thid * 4;
        gPrefixGroupSums.Store(addr, gSharedData[thid] - leftData + prevIterSum);
        DeviceMemoryBarrierWithGroupSync();
        if (thid == gNumGroups - 1) {
            gTotalSum.Store(0, gSharedData[thid] + prevIterSum); // store total sum
        }
    }
    if ((thid + GROUP_SIZE) < gNumGroups) {
        uint addr = (thid + GROUP_SIZE) * 4;
        gPrefixGroupSums.Store(addr, gSharedData[thid + GROUP_SIZE] - rightData + prevIterSum);
        DeviceMemoryBarrierWithGroupSync();
        if (thid + GROUP_SIZE == gNumGroups - 1) {
            gTotalSum.Store(0, gSharedData[thid + GROUP_SIZE] + prevIterSum); // store total sum
        }
    }
}

/** Pass for finalizing a prefix sum computed over multiple thread groups.
    Each thread here operates on one element of the data buffer.
    (their group's prefix sum is zero).
*/
[numthreads(GROUP_SIZE, 1, 1)]
void finalizeGroups(uint3 groupID : SV_GroupID, uint3 groupThreadID : SV_GroupThreadID)
{
    const uint thid = groupThreadID.x;      // Local thread ID in the range 0..N-1.
    const uint groupIdx = groupID.x;        // Group index where each group represents N elements.
    uint interGroupPrefixSum = gPrefixGroupSums.Load((groupIdx >> 1) * 4);
    uint globalIdx = (groupIdx * GROUP_SIZE) + thid + 2 * GROUP_SIZE * (2 * GROUP_SIZE * gIter); 

    if (globalIdx < gTotalNumElems)
    {
        uint addr = globalIdx * 4;
        uint elem = gData.Load(addr);
        gData.Store(addr, elem + interGroupPrefixSum);
    }
}
