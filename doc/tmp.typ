
= dead ends (blind ways)

1. handlers
idea: easily stream symbols/vertices over network "one-by-one" or easily change
the coding scheme (or change the output method, print to console to file easily)
bad because: some decoding schemes need to know metadata (number of vertices) in
advance and eg spirale-reversi even need to parse symbols from the end
last commit with handlers: 1e31aff93c1ba7f2195d5e453b1a1a55f7ab8bcb

2. explicit boundary
idea: in original eb. paper the current boundary is stored using half-edges
which I implemented as de-facto linked-list. It seems that for surfaces with
holes and handles (genus > 0) it is better to use triangle-marks and that it is
even simpler that original boundary approach
last commit with explicit boundary: d68b38456ab3cb26135065d7a407bd97de3f1fd4

3. ???
