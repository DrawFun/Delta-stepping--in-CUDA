#ifndef _RELAX_H_
#define _RELAX_H_
#include "vertex.h"

__global__ void
get_result(cpu::vertex* gpu_global_vertex,int des,int src){
	printf("result: %d\n",gpu_global_vertex[des].dist);	
	int pre = gpu_global_vertex[des].pre_vertex;
	printf("(%d,%d)",des,gpu_global_vertex[des].dist);
	while(pre != src){
	   printf(" <- (%d,%d)",pre,gpu_global_vertex[pre].dist);
	   pre = gpu_global_vertex[pre].pre_vertex;
	}
	printf(" <- (%d,%d)\n",src,gpu_global_vertex[src].dist);
}

__global__ void
verify_result(cpu::vertex* gpu_global_vertex,cpu::gpuResult *gpu_result){
const unsigned int tid = threadIdx.x;
//    for(int i=0;i<NUM_BLOCK;i++){
       int count=0;
       cpu::gpuResult* current = &gpu_result[tid*MAX_RESULT_SIZE];
       while(1){
       if(current[count].index==0)
          break;
       	  if(current[count].new_distance<gpu_global_vertex[current[count].index].dist){
//	  	printf("!!!!\n");
		gpu_global_vertex[current[count].index].dist = current[count].new_distance;
		gpu_global_vertex[current[count].index].pre_vertex = current[count].pre;
       	  }
       count++;
       }
//    }
}

__global__ void
bucket_ops(cpu::gpuResult *gpu_result, cpu::gpuSet *gpu_set, int delta){
    for(int i = 0; i < NUM_BLOCK; i++){
        int count = 0;
        cpu::gpuResult *current = &gpu_result[i * MAX_RESULT_SIZE];
        while(1){
            if(current[count].index == 0){
                break;
            }
            printf("!!!%d\n", current[count].index);
            int old_bucket = current[count].old_distance / delta;
            if(old_bucket >= MAX_BUKET_NUM)
                old_bucket = MAX_BUKET_NUM - 1;
            int new_bucket = current[count].new_distance / delta;
            printf("i: %d, old b: %d, new b: %d\n", i, old_bucket, new_bucket);
            //remove
            int old_bucket_count = gpu_set[old_bucket].count;
            int remove_index = current[count].index;
            printf("remove v: %d\n", remove_index);
            for(int j = 0; j < old_bucket_count; j++){
                if(gpu_set[old_bucket].v_array[j] == remove_index){
                    printf("match v: %d, id: %d\n", remove_index, j);
                    if(j != old_bucket_count - 1)
                        gpu_set[old_bucket].v_array[j] =
                            gpu_set[old_bucket].v_array[old_bucket_count - 1];
                    else
                        gpu_set[old_bucket].v_array[j] = 0;
                    old_bucket_count--;
                    j--;
                }
            }
            gpu_set[old_bucket].count = old_bucket_count;
            //insert
            int new_bucket_count = gpu_set[new_bucket].count;
            gpu_set[new_bucket].v_array[new_bucket_count] = current[count].index;
            gpu_set[new_bucket].count++;
            printf("i: %d, new b: %d, count: %d, v: %d\n", i, new_bucket,
                    new_bucket_count, current[count].index);
            if(gpu_set[new_bucket].count >= MAX_BUCKET_SIZE)
                printf("bucket BOOM!\n");
            count++;
        }
    }
    //init
    for(int i = 0; i < NUM_BLOCK; i++){
        for(int j = 0; j < MAX_RESULT_SIZE; j++){
            gpu_result[i * MAX_RESULT_SIZE + j].index = 0;
        }
    }
}

__global__ void
find_min_no_empty_bucket(cpu::gpuSet* gpu_set, int* gpu_vertex_buf, int* min){
    int i = 0;
    for(i = 0; i < MAX_BUKET_NUM; i++){
        if(gpu_set[i].count != 0)
            break;
    }
    *min = i;
    //init 
    for(int k = 0; k < V_BUF_SIZE; k++){
        gpu_vertex_buf[k] = 0;
    }
    if(V_BUF_SIZE >= gpu_set[i].count){
        for(int j = 0; j < gpu_set[i].count; j++){
            gpu_vertex_buf[j] = gpu_set[i].v_array[j];
            //printf("%d, ", gpu_vertex_buf[j]);
        }
    }
    else{
        printf("V_BUF BOOM!\n");
    }
    //init
    for(int n = 0; n < gpu_set[i].count; n++){
        gpu_set[i].v_array[n] = 0;
    }
    gpu_set[i].count = 0;
}

__global__ void 
init_gpu_bucket(cpu::gpuSet* gpu_set, int src){
    gpu_set[0].v_array[0] = src;
    gpu_set[0].count = 1;
}
__global__ void
relax_all(int* gpu_vertex_buf, cpu::gpuResult* gpu_used_result_buf,
	       cpu::vertex* gpu_global_vertex, cpu::edge* gpu_global_edge){

    const unsigned int bid = blockIdx.x; 
    const unsigned int num_block = gridDim.x; 
    const unsigned int tid_in_block = threadIdx.x;
    const unsigned int num_thread = blockDim.x;
    const unsigned int tid_in_grid = blockDim.x * blockIdx.x +threadIdx.x;

    int i=0,j=0;
    int dist_current,dest,tent_dest;
    __shared__ int result_count,lock;
    if(tid_in_block==0){
	result_count=0;
	lock=0;
    }

    //one vertex per block
    for (i=bid;i<V_BUF_SIZE;i+=num_block){

        if(gpu_vertex_buf[i] == 0)
            return;

	//get current vertex's info
        //cpu::vertex *temp_v = &gpu_global_vertex[gpu_vertex_buf[i]];
	int edge_index = gpu_global_vertex[gpu_vertex_buf[i]].edge_index;
	cpu::gpuResult *current_result_buf = &gpu_used_result_buf[bid*MAX_RESULT_SIZE]; //the buffer now used
        int num_edges = gpu_global_vertex[gpu_vertex_buf[i]+1].edge_index - edge_index;
        int tent_current = gpu_global_vertex[gpu_vertex_buf[i]].dist;

	//one edge per thread
        for(j=tid_in_block;j<num_edges;j+=num_thread){
		//get edge's info
                dist_current = gpu_global_edge[edge_index+j].distance;
                dest = gpu_global_edge[edge_index+j].des_v;
                tent_dest = gpu_global_vertex[dest].dist;

            //if(tent_current + dist_current > MAX_DISTANCE)
                //printf("DISTANCE BOOM\n");

            if(tent_current + dist_current < gpu_global_vertex[dest].dist){
                gpu_global_vertex[dest].dist = tent_current + dist_current;
		gpu_global_vertex[dest].pre_vertex = gpu_vertex_buf[i];
                  
	    //FIXME: bad critical section
	    int now,loop=0;

while(loop==0){
if(atomicExch(&lock,1)==0){
	    now = result_count;
	    atomicAdd(&result_count,1);
	    loop=1;
	    atomicExch(&lock,0);
	    }
}
		current_result_buf[now].index = dest;
            	current_result_buf[now].old_distance = tent_dest;
            	current_result_buf[now].new_distance = (tent_current+dist_current);
		current_result_buf[now].pre = gpu_vertex_buf[i];
//if(result_count>=MAX_RESULT_SIZE)
//	printf("OVERFLOW!!!!%d\n", result_count);
//printf("%d %d %d\n",dest,tent_dest,tent_current+dist_current);
printf("GPU:%d->%d old:%d new:%d %d %d\n",gpu_vertex_buf[i],current_result_buf[now].index,current_result_buf[now].old_distance,current_result_buf[now].new_distance,now,result_count);
        }
	}
    }
 }



#endif
