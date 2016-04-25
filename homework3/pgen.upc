#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/time.h>
#include <math.h>
#include <time.h>
#include <upc.h>

#include "packingDNAseq.h"
#include "kmer_hash.h"

int add_kmer2(hash_table_t *hashtable, memory_heap_t *memory_heap, shared [] char * packedKmer, int64_t hashval, char left_ext, char right_ext)
{
	int64_t pos = memory_heap->posInHeap;

	/* Add the contents to the appropriate kmer struct in the heap */
	upc_memget((memory_heap->heap[pos]).kmer, packedKmer, KMER_PACKED_LENGTH * sizeof(char));
	(memory_heap->heap[pos]).l_ext = left_ext;
	(memory_heap->heap[pos]).r_ext = right_ext;

	/* Fix the next pointer to point to the appropriate kmer struct */
	(memory_heap->heap[pos]).next = hashtable->table[hashval].head;
	/* Fix the head pointer of the appropriate bucket to point to the current kmer */
	hashtable->table[hashval].head = &(memory_heap->heap[pos]);

	/* Increase the heap pointer */
	memory_heap->posInHeap++;

	return 0;
}


int main(int argc, char *argv[]){

	/** Declarations **/
	double inputTime=0.0, constrTime=0.0, traversalTime=0.0;



	//Copied variables
	char cur_contig[MAXIMUM_CONTIG_SIZE], unpackedKmer[KMER_LENGTH+1], left_ext, right_ext, *input_UFX_name;
	int64_t posInContig, contigID = 0, totBases = 0, ptr = 0, nKmers, cur_chars_read, total_chars_to_read;
	unpackedKmer[KMER_LENGTH] = '\0';
	kmer_t *cur_kmer_ptr;
	start_kmer_t *startKmersList = NULL, *curStartNode;
	unsigned char *working_buffer;
	FILE *inputFile, *serialOutputFile;
	/* Read the input file name */
	input_UFX_name = argv[1];
	//End copied variables





	/** Read input **/
	upc_barrier;
	inputTime -= gettime();
	///////////////////////////////////////////
	// Your code for input file reading here //
	///////////////////////////////////////////
	/* Initialize lookup table that will be used for the DNA packing routines */
	init_LookupTable();

	/* Extract the number of k-mers in the input file */
	nKmers = getNumKmersInUFX(input_UFX_name);

	shared kmerPlain_t *kmerArray = upc_all_alloc(nKmers, sizeof(kmerPlain_t));

	kmerPlain_t *privateKmerArray = (kmerPlain_t*)malloc(nKmers * sizeof(kmerPlain_t));

	upc_barrier;

	hash_table_t *hashtable;
	memory_heap_t memory_heap;

	/* Create a hash table */
	hashtable = create_hash_table(nKmers, &memory_heap);

	/* Read the kmers from the input file and store them in the working_buffer */
	total_chars_to_read = nKmers * LINE_SIZE;
	working_buffer = (unsigned char*) malloc(total_chars_to_read * sizeof(unsigned char));
	inputFile = fopen(input_UFX_name, "r");


	cur_chars_read = fread(working_buffer, sizeof(unsigned char),total_chars_to_read , inputFile);

	fclose(inputFile);

	//unsigned char *working_buffer2 = (unsigned char*) malloc(total_chars_to_read * sizeof(unsigned char));
	//memcpy(working_buffer2, working_buffer, total_chars_to_read);

	int start = 0;
	int len = LINE_SIZE;

	upc_barrier;
	inputTime += gettime();

	/** Graph construction **/
	constrTime -= gettime();
	///////////////////////////////////////////
	// Your code for graph construction here //
	///////////////////////////////////////////
/* Process the working_buffer and store the k-mers in the hash table */
	/* Expected format: KMER LR ,i.e. first k characters that represent the kmer, then a tab and then two chatacers, one for the left (backward) extension and one for the right (forward) extension */

	int myThread = MYTHREAD;
	int numOfThreads = THREADS;
	int startKMers = nKmers * MYTHREAD / THREADS;
	int endKMers = nKmers * (MYTHREAD+1) / THREADS;

	for (ptr = startKMers; ptr < endKMers; ptr++) {
		int index = ptr * LINE_SIZE;

		left_ext = (char) working_buffer[index+KMER_LENGTH+1];
		right_ext = (char) working_buffer[index+KMER_LENGTH+2];

		char packedKmer[KMER_PACKED_LENGTH];

		char sequence[KMER_LENGTH];
		memcpy(sequence, working_buffer, KMER_LENGTH);
		packSequence((unsigned char*)&sequence, (unsigned char*) packedKmer, KMER_LENGTH);

		int64_t hashval = hashkmer(hashtable->size, (char*) packedKmer);

		kmerPlain_t temp;
		temp.l_ext = left_ext;
		temp.hashval = hashval;
		temp.r_ext = right_ext;

		memcpy(temp.kmer, packedKmer, KMER_PACKED_LENGTH * sizeof(char));

		upc_memput( (shared void *) (kmerArray+ptr),  &temp, sizeof(kmerPlain_t));
	}

	//Now for private kmer reads
	for (ptr = 0; ptr < nKmers; ptr++) {
		int index = ptr * LINE_SIZE;

		left_ext = (char) working_buffer[index+KMER_LENGTH+1];
		right_ext = (char) working_buffer[index+KMER_LENGTH+2];

		char packedKmer[KMER_PACKED_LENGTH];

		char sequence[KMER_LENGTH];
		memcpy(sequence, working_buffer, KMER_LENGTH);
		packSequence((unsigned char*)&sequence, (unsigned char*) packedKmer, KMER_LENGTH);

		int64_t hashval = hashkmer(hashtable->size, (char*) packedKmer);

		privateKmerArray[ptr].l_ext = left_ext;
		privateKmerArray[ptr].hashval = hashval;
		privateKmerArray[ptr].r_ext = right_ext;

		memcpy(privateKmerArray[ptr].kmer, packedKmer, KMER_PACKED_LENGTH * sizeof(char));

		//upc_memput( (shared void *) (kmerArray+ptr),  &temp, sizeof(kmerPlain_t));
	}

	upc_barrier;


	//Add all the kmers to the hash table
	for (ptr = 0; ptr < nKmers; ptr++) {

		int index = ptr * LINE_SIZE;

		left_ext = (char) working_buffer[index+KMER_LENGTH+1];
		right_ext = (char) working_buffer[index+KMER_LENGTH+2];

		if (privateKmerArray[ptr].l_ext != left_ext || privateKmerArray[ptr].r_ext != right_ext) {
			printf("ERROR WRONG EXTENSIONS\n");
			fflush(stdout);
		}


		char packedKmer[KMER_PACKED_LENGTH];
		packSequence(&working_buffer[index], (unsigned char*) packedKmer, KMER_LENGTH);
		int64_t hashval = hashkmer(hashtable->size, (char*) packedKmer);

		if (hashval != privateKmerArray[ptr].hashval) {
			printf("ERROR WRONG HASH\n");
			fflush(stdout);
		}

		add_kmerPrepared(hashtable, &memory_heap, privateKmerArray[ptr].kmer, privateKmerArray[ptr].hashval, privateKmerArray[ptr].l_ext, privateKmerArray[ptr].r_ext);

		if (kmerArray[ptr].l_ext == 'F') {

			addKmerToStartList(&memory_heap, &startKmersList);
		}
	}

/*
	//Loops through each line of string data
	for (ptr = 0; ptr < cur_chars_read; ptr += LINE_SIZE) {

		int kmerIndex = ptr / LINE_SIZE;
		//printf("kmerIndex: %d on thread %d\n", kmerIndex, myThread);
		//fflush(stdout);


		left_ext = (char) working_buffer[ptr+KMER_LENGTH+1];
		right_ext = (char) working_buffer[ptr+KMER_LENGTH+2];

		char left1 = left_ext;
		char right1 = right_ext;

		char left2 = kmerArray[kmerIndex].l_ext;
		char right2 = kmerArray[kmerIndex].r_ext;

		//if (myThread == 0) {

			if (left1 != left2 || right1 != right2) {
				printf("kmerIndex: %d, Thread: %d, %c%c != %c%c\n", kmerIndex, myThread, left1, right1, left2, right2);
				printf("Reading from buffer on thread %d at kmer: %d:  %.*s\n", MYTHREAD, kmerIndex, LINE_SIZE, working_buffer + ptr);
				fflush(stdout);
			}

			//printf("kmerIndex: %d, kmer Extension: %c%c vs %c%c on thread %d\n", kmerIndex, kmerArray[ptr].l_ext,
			//	   kmerArray[ptr].r_ext, left_ext, right_ext, myThread);
			//fflush(stdout);

		//}

		add_kmer(hashtable, &memory_heap, &working_buffer[ptr], left_ext, right_ext);

		if (left_ext == 'F') {
			addKmerToStartList(&memory_heap, &startKmersList);
		}

	}
*/
	printf("Done with construction on thread %d\n", MYTHREAD);
	fflush(stdout);







	upc_barrier;
	constrTime += gettime();

	/** Graph traversal **/
	traversalTime -= gettime();


	printf("Starting graph traversal on thread %d\n", MYTHREAD);
	fflush(stdout);

	if (MYTHREAD == 0) {

		////////////////////////////////////////////////////////////
		// Your code for graph traversal and output printing here //
		// Save your output to "pgen.out"                         //
		////////////////////////////////////////////////////////////
		serialOutputFile = fopen("pgen.out", "w");

		/* Pick start nodes from the startKmersList */
		curStartNode = startKmersList;

		while (curStartNode != NULL) {
			/* Need to unpack the seed first */
			cur_kmer_ptr = curStartNode->kmerPtr;
			unpackSequence((unsigned char *) cur_kmer_ptr->kmer, (unsigned char *) unpackedKmer, KMER_LENGTH);
			/* Initialize current contig with the seed content */
			memcpy(cur_contig, unpackedKmer, KMER_LENGTH * sizeof(char));
			posInContig = KMER_LENGTH;
			right_ext = cur_kmer_ptr->r_ext;

			/* Keep adding bases while not finding a terminal node */
			while (right_ext != 'F') {
				cur_contig[posInContig] = right_ext;
				posInContig++;
				/* At position cur_contig[posInContig-KMER_LENGTH] starts the last k-mer in the current contig */
				cur_kmer_ptr = lookup_kmer(hashtable, (const unsigned char *) &cur_contig[posInContig - KMER_LENGTH]);
				right_ext = cur_kmer_ptr->r_ext;
			}

			/* Print the contig since we have found the corresponding terminal node */
			cur_contig[posInContig] = '\0';
			fprintf(serialOutputFile, "%s\n", cur_contig);
			contigID++;
			totBases += strlen(cur_contig);
			/* Move to the next start node in the list */
			curStartNode = curStartNode->next;
		}

		fclose(serialOutputFile);

	}

	printf("Done with graph traversal on thread %d\n", MYTHREAD);
	fflush(stdout);







	upc_barrier;
	traversalTime += gettime();

	printf("Job finished on thread %d\n", MYTHREAD);
	fflush(stdout);

	/** Print timing and output info **/
	/***** DO NOT CHANGE THIS PART ****/
	if(MYTHREAD==0){
		printf("%s: Input set: %s\n", argv[0], argv[1]);
		printf("Number of UPC threads: %d\n", THREADS);
		printf("Input reading time: %f seconds\n", inputTime);
		printf("Graph construction time: %f seconds\n", constrTime);
		printf("Graph traversal time: %f seconds\n", traversalTime);
	}
	return 0;
}
