//------------------------------------------------------------------------------
// name: music-collab.ck 
// desc: An interactive tool where user provides a phrase of music via microphone, 
//       then the program produces a similar musical phrase, and then the user 
//       provides input again, and the program plays another sequence in response, 
//       and so on. The user also has to specify the rhythmic structure of the piece
//       before hand.
//
// USAGE: simply run the following:
//        > chuck music-collab.ck
//
// uncomment the next line to learn more about the KNN2 object:
// KNN2.help();
//
// date: Spring 2023
// author: Andrew T. Lee
//------------------------------------------------------------------------------

// ---------------------------- Initializations --------------------------------

// features file for database file
"data/song.txt" => string DATABASE_FILE; 


// Set Up Metronome
Shakers metronome => dac;
6 => metronome.preset;
0.7 => metronome.energy;
0.1 => metronome.decay;

// Set Up Recording Device LiSa
adc => LiSa saveme;


// Unit Analyzer Network
// audio input into a FFT
saveme => FFT fft;
FeatureCollector combo => blackhole;
fft =^ Centroid centroid =^ combo;    // size 1
fft =^ Flux flux =^ combo;    // size 1
fft =^ RMS rms =^ combo;    // size 1
fft =^ Chroma chroma =^ combo;    // size 12
fft =^ MFCC mfcc =^ combo;    // size 20


// Setting Analysis Parameters
// set number of coefficients in MFCC (how many we get out)
// 13 is a commonly used value; using less here for printing
13 => mfcc.numCoeffs;
// set number of mel filters in MFCC
10 => mfcc.numFilters;
// do one .upchuck() so FeatureCollector knows how many total dimension
combo.upchuck();
// get number of total feature dimensions
combo.fvals().size() => int NUM_DIMENSIONS;
// set FFT size
4096 => fft.size;
// set window type and size
Windowing.hann(fft.size()) => fft.window;
// how many frames to aggregate before averaging?
16 => int NUM_FRAMES;
// our hop size (how often to perform analysis)
(fft.size()/2)::samp => dur HOP;
// how much time to aggregate features for each file
fft.size()::samp * NUM_FRAMES => dur EXTRACT_TIME;


// Unit Generator Network: for real-time sound Analysis
// how many max at any time?
6 => int NUM_VOICES;
// a number of audio buffers to cycle between
SndBuf buffers[NUM_VOICES]; ADSR envs[NUM_VOICES]; Pan2 pans[NUM_VOICES];
Gain MosaicVol;
// set parameters
for( int i; i < NUM_VOICES; i++ )
{
    // connect audio
    buffers[i] => envs[i] => pans[i] => MosaicVol => NRev reverb => dac;
    0.6 => MosaicVol.gain;
    0.25 => reverb.mix;
    // set chunk size (how to to load at a time)
    // this is important when reading from large files
    // if this is not set, SndBuf.read() will load the entire file immediately
    fft.size() => buffers[i].chunks;
    // randomize pan
    Math.random2f(-.75,.75) => pans[i].pan;
    // set envelope parameters
    envs[i].set( EXTRACT_TIME, EXTRACT_TIME/2, 1, EXTRACT_TIME );
}


// Load Database File's Feature Data
0 => int numPoints; // number of points/audio windows in database file
0 => int numCoeffs; // number of dimensions in data
// file read, PART 1: read over the file to get numPoints and numCoeffs
loadFile( DATABASE_FILE ) @=> FileIO @ fin;
// check
if( !fin.good() ) me.exit();
// check dimension at least
if( numCoeffs != NUM_DIMENSIONS )
{
    // error
    <<< "[error] expecting:", NUM_DIMENSIONS, "dimensions; but features file has:", numCoeffs >>>;
    // stop
    me.exit();
}


// Audio Window: each Point corresponds to one line in the database file
class AudioWindow
{
    // unique point index (use this to lookup feature vector)
    int uid;
    // which file did this come file (in files arary)
    int fileIndex;
    // starting time in that file (in seconds)
    float windowTime;
    
    // set
    fun void set( int id, int fi, float wt )
    {
        id => uid;
        fi => fileIndex;
        wt => windowTime;
    }
}
AudioWindow windows[numPoints];  // array of all points in model file
string files[0];  // unique filenames; we will append to this
int filename2state[0];  // map of filenames loaded
float inFeatures[numPoints][numCoeffs];  // feature vectors of data points
int uids[numPoints]; for( int i; i < numPoints; i++ ) i => uids[i];  // generate array of unique indices
float features[NUM_FRAMES][numCoeffs];  // use this for new input
float featureMean[numCoeffs]; // // average values of coefficients across frames


// Read Database File
readData( fin );


// Set Up KNN object used for classification
KNN2 knn;
6 => int K;
int knnResult[K];  // results vector (indices of k nearest points)
knn.train( inFeatures, uids );  // knn train
0 => int which;  // used to rotate sound buffers






// ---------------------------- Helper Functions -------------------------------

// loadFile: loads database file
fun FileIO loadFile( string filepath )
{
    // reset
    0 => numPoints;
    0 => numCoeffs;
    
    // load data
    FileIO fio;
    if( !fio.open( filepath, FileIO.READ ) )
    {
        // error
        <<< "cannot open file:", filepath >>>;
        // close
        fio.close();
        // return
        return fio;
    }
    
    string str;
    string line;
    // read the first non-empty line
    while( fio.more() )
    {
        // read each line
        fio.readLine().trim() => str;
        // check if empty line
        if( str != "" )
        {
            numPoints++;
            str => line;
        }
    }
    
    // a string tokenizer
    StringTokenizer tokenizer;
    // set to last non-empty line
    tokenizer.set( line );
    // negative (to account for filePath windowTime)
    -2 => numCoeffs;
    // see how many, including label name
    while( tokenizer.more() )
    {
        tokenizer.next();
        numCoeffs++;
    }
    
    // see if we made it past the initial fields
    if( numCoeffs < 0 ) 0 => numCoeffs;
    
    // check
    if( numPoints == 0 || numCoeffs <= 0 )
    {
        <<< "no data in file:", filepath >>>;
        fio.close();
        return fio;
    }
    
    // print
    // <<< "# of data points:", numPoints, "dimensions:", numCoeffs >>>;
    
    // done for now
    return fio;
}


// readData: reads data file
fun void readData( FileIO fio )
{
    // rewind the file reader
    fio.seek( 0 );
    
    // a line
    string line;
    // a string tokenizer
    StringTokenizer tokenizer;
    
    // points index
    0 => int index;
    // file index
    0 => int fileIndex;
    // file name
    string filename;
    // window start time
    float windowTime;
    // coefficient
    int c;
    
    // read the first non-empty line
    while( fio.more() )
    {
        // read each line
        fio.readLine().trim() => line;
        // check if empty line
        if( line != "" )
        {
            // set to last non-empty line
            tokenizer.set( line );
            // file name
            tokenizer.next() => filename;
            // window start time
            tokenizer.next() => Std.atof => windowTime;
            // have we seen this filename yet?
            if( filename2state[filename] == 0 )
            {
                // append
                files << filename;
                // new id
                files.size() => filename2state[filename];
            }
            // get fileindex
            filename2state[filename]-1 => fileIndex;
            // set
            windows[index].set( index, fileIndex, windowTime );
            
            // zero out
            0 => c;
            // for each dimension in the data
            repeat( numCoeffs )
            {
                // read next coefficient
                tokenizer.next() => Std.atof => inFeatures[index][c];
                // increment
                c++;
            }
            
            // increment global index
            index++;
        }
    }
}


// synthesize: takes in an uid and plays the corresponding audio window
fun void synthesize( int uid, dur synthTime )
{
    // get the buffer to use
    buffers[which] @=> SndBuf @ sound;
    // get the envelope to use
    envs[which] @=> ADSR @ envelope;
    // increment and wrap if needed
    which++; if( which >= buffers.size() ) 0 => which;
    
    // get a reference to the audio fragment to synthesize
    windows[uid] @=> AudioWindow @ win;
    // get filename
    files[win.fileIndex] => string filename;
    // load into sound buffer
    filename => sound.read;
    // seek to the window start time
    ((win.windowTime::second)/samp) $ int => sound.pos;
    
    // print what we are about to play
    /***
    chout <= "synthsizing window: ";
    // print label
    chout <= win.uid <= "["
    <= win.fileIndex <= ":"
    <= win.windowTime <= ":POSITION="
    <= sound.pos() <= "]";
    // endline
    chout <= IO.newline();
    ***/

    
    envelope.keyOn();
    // wait
    synthTime => now;
    // start the release
    envelope.keyOff();
    // wait
    envelope.releaseTime() => now;
}


// similarityRetrieval: synthesizes stored user input
fun void similarityRetrieval( dur synthTime ) {
    200::ms => dur frameTime;
    while ( true ) {
        // aggregate features over a period of time
        for( int frame; frame < NUM_FRAMES; frame++ ) {
            combo.upchuck();
            for( int d; d < NUM_DIMENSIONS; d++) {
                combo.fval(d) => features[frame][d];
            }
            ( frameTime / NUM_FRAMES )  => now;
        }
        if (synthTime > frameTime ) {
            synthTime - frameTime => now;
        }   
        // compute means for each coefficient across frames
        for( int d; d < NUM_DIMENSIONS; d++ ) {
            0.0 => featureMean[d];
            for( int j; j < NUM_FRAMES; j++ ) {
                features[j][d] +=> featureMean[d];
            }
            NUM_FRAMES /=> featureMean[d];
        }
        knn.search( featureMean, K, knnResult );
        spork ~ synthesize( knnResult[Math.random2(0,knnResult.size()-1)], synthTime );
    }
}


// setPulse: provides a metronome
fun void setPulse(dur beat, int beatsPerMeasure, int measuresPerPhrase) {
    // measure of rest
    80 => Std.mtof => metronome.freq;
    0.9 => metronome.noteOn;
    beat => now;
    for (beatsPerMeasure - 1 => int i; i > 0; i--) {
        50 => Std.mtof => metronome.freq;
        0.3 => metronome.noteOn;
        beat => now;
    }
    
    // shift between user and computer turns
    while ( true ) {
        // user turn
        for (int b; b < beatsPerMeasure*measuresPerPhrase; b++) {
            if (b % beatsPerMeasure == 0) {
                80 => Std.mtof => metronome.freq;
                0.9 => metronome.noteOn;
            } else {
                50 => Std.mtof => metronome.freq;
                0.3 => metronome.noteOn;
            }
            beat => now;
        }
        // mosaic turn
        for (int b; b < beatsPerMeasure*measuresPerPhrase; b++) {
            if (b % beatsPerMeasure == 0) {
                60 => Std.mtof => metronome.freq;
                0.9 => metronome.noteOn;
            } else {
                30 => Std.mtof => metronome.freq;
                0.3 => metronome.noteOn;
            }
            beat => now;
        }
    }
}


// storeNplay: stores user's audio input into saveme, then replays it 
fun void storeNplay(dur phrase, dur beat) {
    while ( true ) {
        // User Input
        chout <= "Your Turn to Play!";
        chout <= IO.newline();
        saveme.record(1);
        phrase - beat => now;    
        saveme.record(0);
        beat => now;
        
        // Synthesis
        chout <= "My Turn (synthesizing what you just played)!";
        chout <= IO.newline(); 
        saveme.play(1);
        phrase => now;
        saveme.play(0);
    }
}






// ---------------------------- Main Code --------------------------------------

// Preset duet settings before starting to perform
ConsoleInput in;
in.prompt( "What BPM tempo would you like to use?" ) => now;
Std.atoi(in.getLine()) => int BPM; 
(60.0 / BPM)::second => dur beat;
in.prompt( "How many beats per measure?" ) => now;
Std.atoi(in.getLine()) => int beatsPerMeasure; 
beat*beatsPerMeasure => dur measure;
in.prompt( "How many measures would you like a phrase to be?" ) => now;
Std.atoi(in.getLine()) => int measuresPerPhrase;
measure*measuresPerPhrase => dur phrase;
phrase => saveme.duration;

// Preparational Info
1::second => now;
chout <= IO.newline();
chout <= "Presetting Complete! Your duet will be at "<= BPM 
      <= " BPM with " <= beatsPerMeasure <= " beats per measure.";
chout <= IO.newline();
chout <= "Each turn will take "<= measuresPerPhrase <= " measures.";
chout <= IO.newline();
chout <= "You will start after 1 measure of rest, stay in time and have fun!";
chout <= IO.newline() <= IO.newline();
2::second => now;

// Dueting
adc => dac;
spork ~ setPulse( beat, beatsPerMeasure, measuresPerPhrase );
measure => now;
spork ~ storeNplay( phrase, beat );
(phrase - beat) => now;
spork ~ similarityRetrieval( beat );
beat => now;
while ( true ) {
    // mosaic play
    0.6 => MosaicVol.gain;
    measure*(measuresPerPhrase-1) => now;
    0.0 => MosaicVol.gain; // use last measure to transition to player
    measure => now;
    
    // user play
    phrase => now;
}



