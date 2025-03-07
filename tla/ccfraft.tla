--------------------------------- MODULE ccfraft ---------------------------------
\* This is the formal specification for the Raft consensus algorithm.
\*
\* Copyright 2014 Diego Ongaro.
\* Modifications Copyright 2021 Microsoft.
\* This work is licensed under the Creative Commons Attribution-4.0
\* International License https://creativecommons.org/licenses/by/4.0/

\* Modified for CCF by Microsoft Research
\* Author of these modifications:
\*      Fritz Alder <fritz.alder@acm.org>
\*      Heidi Howard <heidi.howard@microsoft.com>
\*      Markus Alexander Kuppe <makuppe@microsoft.com>
\* Partially based on
\* - https://github.com/ongardie/raft.tla/blob/master/raft.tla
\*   (base spec, modified)
\* - https://github.com/jinlmsft/raft.tla/blob/master/raft.tla
\*   (e.g. clientRequests, committedLog)
\* - https://github.com/dricketts/raft.tla/blob/master/raft.tla
\*   (e.g. certain invariants)

EXTENDS Naturals, FiniteSets, Sequences, TLC, FiniteSetsExt, SequencesExt, Functions

----
\* Constants

\* Server states
CONSTANTS
    \* See original Raft paper (https://www.usenix.org/system/files/conference/atc14/atc14-paper-ongaro.pdf)
    \* and comments for leadership_state in../src/consensus/aft/raft.h for details on the Follower,
    \* Candidate, and Leader states.
    Follower,
    Candidate,
    Leader,
    \* CCF adds the RetiredLeader state to the protocol: A Leader transitions to RetiredLeader
    \* after committing a reconfiguration transaction which removes the Leader from the
    \* configuration (see also ../src/consensus/aft/raft.h).
    \* More formally: 
    \*   /\ [][\E s \in Servers: state'[s] = RetiredLeader => state[s] = Leader]_state
    \*   /\ [][\A s \in Servers:
    \*          /\ state[s] = Leader
    \*          /\  CurrentConfiguration(s) \ CurrentConfiguration(s)' = {s}
    \*          => state'[s] = RetiredLeader]_state
    RetiredLeader,
    \* The node has passed attestation checks, but is waiting for member confirmation, 
    \* and just isn't part of any configurations at all, nor has a communication channel
    \* with other nodes (Pending is *not* Learner in 
    \* https://microsoft.github.io/CCF/main/architecture/consensus/1tx-reconfig.html).
    \* More formally:
    \*   \A i \in Servers : state[i] = Pending => i \notin { GetServerSet(s) : s \in Servers}
    Pending

States == {
    Follower,
    Candidate,
    Leader,
    RetiredLeader,
    Pending
    }

\* A reserved value
CONSTANTS Nil

\* Message types:
CONSTANTS
    RequestVoteRequest,
    RequestVoteResponse,
    AppendEntriesRequest,
    AppendEntriesResponse,
    NotifyCommitMessage

\* CCF: Content types (Normal entry or a signature that signs
\*      previous entries or a reconfiguration entry)
CONSTANTS
    TypeEntry,
    TypeSignature,
    TypeReconfiguration

CONSTANTS
    NodeOne,
    NodeTwo,
    NodeThree,
    NodeFour,
    NodeFive

AllServers == {
    NodeOne,
    NodeTwo,
    NodeThree,
    NodeFour,
    NodeFive
}

\* Set of nodes for this model
CONSTANTS Servers
ASSUME Servers /= {}
ASSUME Servers \subseteq AllServers

----
\* Global variables

\* Keep track of current number of reconfigurations to limit it through the MC.
\* TLC: Finite state space.
VARIABLE reconfigurationCount
\* Each server keeps track of the pending configurations
VARIABLE configurations
\* The set of servers that have been removed from configurations.  The implementation
\* assumes that a server refrains from rejoining a configuration if it has been removed
\* from an earlier configuration (relying on the TEE and absent Byzantine fault). Here,
\* we model removedFromConfiguration as a global variable. In the implementation, this
\* state has to be maintained by each node separately.
\* Note that we cannot determine the removed servers from configurations because a prefix
\* of configurations is removed from the configuration on a change of configuration.
\* TODO: How does the implementation keep track of removed servers?  Can we remove and
\* TODO: re-add a server in a raft_scenario test?
VARIABLE removedFromConfiguration

reconfigurationVars == <<reconfigurationCount, removedFromConfiguration, configurations>>

\* A set representing requests and responses sent from one server
\* to another. With CCF, we have message integrity and can ensure unique messages.
\* Messages only records messages that are currently in-flight, actions should
\* removed messages once received.
VARIABLE messages

\* CCF: Keep track of each append entries message sent from each server to each other server
\* and cap it to a maximum to constraint the state-space for model-checking.
\* TLC: Finite state space.
VARIABLE messagesSent

\* CCF: After reconfiguration, a RetiredLeader leader may need to notify servers
\* of the current commit level to ensure that no deadlock is reached through
\* leaving the network after retirement (as that would lead to endless leader
\* re-elects and drop-outs until f is reached and network fails).
VARIABLE commitsNotified

messageVars == <<messages, messagesSent, commitsNotified>>
----
\* The following variables are all per server (functions with domain Servers).

\* The server's term number.
VARIABLE currentTerm

\* The server's state.
VARIABLE state

\* The candidate the server voted for in its current term, or
\* Nil if it hasn't voted for any.
VARIABLE votedFor

serverVars == <<currentTerm, state, votedFor>>

\* The set of requests that can go into the log. 
\* TLC: Finite state space.
VARIABLE clientRequests

\* A Sequence of log entries. The index into this sequence is the index of the
\* log entry. Unfortunately, the Sequence module defines Head(s) as the entry
\* with index 1, so be careful not to use that!
VARIABLE log

\* The index of the latest entry in the log the state machine may apply.
VARIABLE commitIndex

\* The log and index denoting the operations that have been committed. Instead
\* of copying the committed prefix of the current leader's log, remember the
\* node and the index (up to which the operations have been committed) into its log.
\* This variable is a history variable in TLA+ jargon. It does not exist in an implementation.
VARIABLE committedLog

logVars == <<log, commitIndex, clientRequests, committedLog>>

\* The set of servers from which the candidate has received a vote in its
\* currentTerm.
VARIABLE votesGranted

\* State space limitation: Restrict each node to send a limited amount
\* of requests to other nodes.
\* TLC: Finite state space.
VARIABLE votesRequested

candidateVars == <<votesGranted, votesRequested>>

\* The following variables are used only on leaders:
\* The next entry to send to each follower.
VARIABLE nextIndex

\* The latest entry that each follower has acknowledged is the same as the
\* leader's. This is used to calculate commitIndex on the leader.
VARIABLE matchIndex

leaderVars == <<nextIndex, matchIndex>>

\* End of per server variables.
----

\* All variables; used for stuttering (asserting state hasn't changed).
vars == <<reconfigurationVars, messageVars, serverVars, candidateVars, leaderVars, logVars>>

----
\* Fine-grained state constraint "hooks" for model-checking with TLC.

\* State limitation: Limit requested votes
InRequestVoteLimit(i,j) ==
    TRUE

\* Limit on terms
\* By default, all servers start as followers in term one
\* So this should therefore be at least two
InTermLimit(i) ==
    TRUE

\* CCF: Limit how many identical append entries messages each node can send to another
InMessagesLimit(i, j, index) ==
    TRUE

\* CCF: Limit the number of commit notifications per commit Index and server
InCommitNotificationLimit(i) ==
    TRUE

\* Limit max number of simultaneous candidates
\* We made several restrictions to the state space of Raft. However since we
\* made these restrictions, Deadlocks can occur at places that Raft would in
\* real-world deployments handle graciously.
\* One example of this is if a Quorum of nodes becomes Candidate but can not
\* timeout anymore since we constrained the terms. Then, an artificial Deadlock
\* is reached. We solve this below. If TermLimit is set to any number >2, this is
\* not an issue since breadth-first search will make sure that a similar
\* situation is simulated at term==1 which results in a term increase to 2.
InMaxSimultaneousCandidates(i) ==
    TRUE

\* Limit on client requests
InRequestLimit ==
    TRUE

IsInConfigurations(i, newConfiguration) ==
    TRUE

\* Helpers

min(a, b) == IF a < b THEN a ELSE b

max(a, b) == IF a > b THEN a ELSE b

RestrictPred(f, Test(_)) ==
    Restrict(f, { x \in DOMAIN f : Test(x) })

\* Helper for Send and Reply. Given a message m and set of messages, return a
\* new set of messages with one more m in it.
WithMessage(m, msgs) == msgs \union {m}

\* Helper for Discard and Reply. Given a message m and bag of messages, return
\* a new bag of messages with one less m in it.
WithoutMessage(m, msgs) == msgs \ {m}

\* Add a message to the bag of messages.
\* But only if this exact messages does not already exist
Send(m) == messages' =
    WithMessage(m, messages)

\* Remove a message from the bag of messages. Used when a server is done
\* processing a message.
Discard(m) == messages' = WithoutMessage(m, messages)

\* Combination of Send and Discard
Reply(response, request) ==
    messages' = WithoutMessage(request, WithMessage(response, messages))

HasTypeSignature(e) == e.contentType = TypeSignature

\* CCF: Return the index of the latest committable message
\*      (i.e., the last one that was signed by a leader)
MaxCommittableIndex(xlog) ==
    SelectLastInSeq(xlog, HasTypeSignature)

\* CCF: Returns the term associated with the MaxCommittableIndex(xlog)
MaxCommittableTerm(xlog) ==
    LET iMax == MaxCommittableIndex(xlog)
    IN IF iMax = 0 THEN 0 ELSE xlog[iMax].term

Quorums ==
    \* Helper function to calculate the Quorum. Needed on each reconfiguration
    [ s \in SUBSET Servers |-> {i \in SUBSET(s) : Cardinality(i) * 2 > Cardinality(s)} ]
    

GetServerSetForIndex(server, index) ==
    \* Pick the sets of servers (aka configs) up to that index
    \* The union of all ranges/co-domains of the currentConfigurations for server up to and including the index.
    UNION { configurations[server][f] : f \in { i \in DOMAIN configurations[server] : i <= index } }

IsInServerSetForIndex(candidate, server, index) ==
    \E i \in { i \in DOMAIN configurations[server] : index >= i } :
        candidate \in configurations[server][i]

\* Pick the union of all servers across all configurations
GetServerSet(server) ==
    UNION (Range(configurations[server]))

IsInServerSet(candidate, server) ==
    \E i \in DOMAIN (configurations[server]) :
        candidate \in configurations[server][i]

CurrentConfigurationIndex(server) ==
    Min(DOMAIN configurations[server])

CurrentConfiguration(server) ==
    configurations[server][CurrentConfigurationIndex(server)]

MaxConfigurationIndex(server) ==
    Max(DOMAIN configurations[server])

MaxConfiguration(server) ==
    configurations[server][MaxConfigurationIndex(server)]

NextConfigurationIndex(server) ==
    LET dom == DOMAIN configurations[server]
    IN Min(dom \ {Min(dom)})

\* The prefix of the log of server i that has been committed
Committed(i) ==
    IF commitIndex[i] = 0
    THEN << >>
    ELSE SubSeq(log[i],1,commitIndex[i])

\* The prefix of the log of server i that has been committed up to term x
CommittedTermPrefix(i, x) ==
    \* Only if log of i is non-empty, and if there exists an entry up to the term x
    IF Len(log[i]) /= 0 /\ \E y \in DOMAIN log[i] : log[i][y].term <= x
    THEN
      \* then, we use the subsequence up to the maximum committed term of the leader
      LET maxTermIndex ==
          CHOOSE y \in DOMAIN log[i] :
            /\ log[i][y].term <= x
            /\ \A z \in DOMAIN log[i] : log[i][z].term <= x  => y >= z
      IN SubSeq(log[i], 1, min(maxTermIndex, commitIndex[i]))
    \* Otherwise the prefix is the empty tuple
    ELSE << >>

----

\* Define initial values for all variables
\* Most variables are used as a TLA function which behaves similar to a Map as known from Python or other programming languages.
\* These variables then map each node to a given value, for example the state variable which maps each node to either Follower,
\* Leader, Retired, or Pending. In the initial state shown below, all nodes states are set to the InitialConfig that is set in MCccfraft.tla.
InitReconfigurationVars ==
    /\ reconfigurationCount = 0
    /\ removedFromConfiguration = {}
    /\ \E c \in SUBSET Servers \ {{}}:
        configurations = [i \in Servers |-> [ j \in {0} |-> c ] ]

InitMessagesVars ==
    /\ messages = {}
    /\ messagesSent = [i \in Servers |-> [j \in Servers |-> << >>] ]
    /\ commitsNotified = [i \in Servers |-> <<0,0>>] \* i.e., <<index, times of notification>>

InitServerVars ==
    /\ currentTerm = [i \in Servers |-> 1]
    /\ state       = [i \in Servers |-> IF i \in configurations[i][0] THEN Follower ELSE Pending]
    /\ votedFor    = [i \in Servers |-> Nil]

InitCandidateVars ==
    /\ votesGranted   = [i \in Servers |-> {}]
    /\ votesRequested = [i \in Servers |-> [j \in Servers |-> 0]]

\* The values nextIndex[i][i] and matchIndex[i][i] are never read, since the
\* leader does not send itself messages. It's still easier to include these
\* in the functions.
InitLeaderVars ==
    /\ nextIndex  = [i \in Servers |-> [j \in Servers |-> 1]]
    /\ matchIndex = [i \in Servers |-> [j \in Servers |-> 0]]

InitLogVars ==
    /\ log          = [i \in Servers |-> << >>]
    /\ commitIndex  = [i \in Servers |-> 0]
    /\ clientRequests = 1
    /\ committedLog = [ node |-> NodeOne, index |-> 0]

Init ==
    /\ InitReconfigurationVars
    /\ InitMessagesVars
    /\ InitServerVars
    /\ InitCandidateVars
    /\ InitLeaderVars
    /\ InitLogVars

----
\* Define state transitions

\* Since TLA does not model time, any node can time out at any moment as a next step.
\* Since this may lead to an infinite state space, we limited the maximum term any node can reach.
\* While this would be overly constraining in any actual program, the model checker will ensure to also explore those states that are feasible within these limits.
\* Since interesting traces can already be generated with one or better two term changes, this approach is feasible to model reconfigurations and check persistence.

\* Server i times out and starts a new election.
Timeout(i) ==
    \* Limit the term of each server to reduce state space
    /\ InTermLimit(i)
    \* Only servers that are not already leaders can become candidates
    /\ state[i] \in {Follower, Candidate}
    \* Limit number of candidates in our relevant server set
    \* (i.e., simulate that not more than a given limit of servers in each configuration times out)
    /\ InMaxSimultaneousCandidates(i)
    \* Check that the reconfiguration which added this node is at least committable
    /\ \E c \in DOMAIN configurations[i] :
        /\ i \in configurations[i][c]
        /\ MaxCommittableIndex(log[i]) >= c
    /\ state' = [state EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    \* Most implementations would probably just set the local vote
    \* atomically, but messaging localhost for it is weaker.
    \*   CCF change: We do this atomically to reduce state space
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesRequested' = [votesRequested EXCEPT ![i] = [j \in Servers |-> 0]]
    /\ votesGranted'   = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<reconfigurationVars, messageVars, leaderVars, logVars>>

\* Candidate i sends j a RequestVote request.
RequestVote(i,j) ==
    LET
        msg == [mtype         |-> RequestVoteRequest,
                mterm         |-> currentTerm[i],
                \*  CCF extension: Use last signature message and not last log entry in elections
                mlastLogTerm  |-> MaxCommittableTerm(log[i]),
                mlastLogIndex |-> MaxCommittableIndex(log[i]),
                msource       |-> i,
                mdest         |-> j]
    IN
    \* Timeout votes for itself atomically. Thus we do not need to request our own vote.
    /\ i /= j
    \* Only requests vote if we are candidate
    /\ state[i] = Candidate
    /\ InRequestVoteLimit(i, j)
    \* Reconfiguration: Make sure j is in a configuration of i
    /\ IsInServerSet(j, i)
    /\ votesRequested' = [votesRequested EXCEPT ![i][j] = votesRequested[i][j] + 1]
    /\ Send(msg)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, serverVars, votesGranted, leaderVars, logVars>>

\* Leader i sends j an AppendEntries request containing up to 1 entry.
\* While implementations may want to send more than 1 at a time, this spec uses
\* just 1 because it minimizes atomic regions without loss of generality.
AppendEntries(i, j) ==
    \* No messages to itself and sender is primary
    /\ state[i] = Leader
    /\ i /= j
    \* Recipient must exist in one configuration relevant to that index
    /\ IsInServerSetForIndex(j, i, nextIndex[i][j])
    \* There must be an index to send
    /\ Len(log[i]) >= nextIndex[i][j]
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm == IF prevLogIndex > 0 /\ prevLogIndex <= Len(log[i]) THEN
                              log[i][prevLogIndex].term
                          ELSE
                              0
           \* Send up to 1 entry, constrained by the end of the log.
           lastEntry == min(Len(log[i]), nextIndex[i][j])
           entries == SubSeq(log[i], nextIndex[i][j], lastEntry)
           msg == [mtype          |-> AppendEntriesRequest,
                   mterm          |-> currentTerm[i],
                   mprevLogIndex  |-> prevLogIndex,
                   mprevLogTerm   |-> prevLogTerm,
                   mentries       |-> entries,
                   mcommitIndex   |-> min(commitIndex[i], MaxCommittableIndex(SubSeq(log[i],1,lastEntry))),
                   msource        |-> i,
                   mdest          |-> j]
           index == nextIndex[i][j]
       IN
       /\ InMessagesLimit(i, j, index)
       /\ messagesSent' =
            IF Len(messagesSent[i][j]) < index
            THEN [messagesSent EXCEPT ![i][j] = Append(messagesSent[i][j], 1) ]
            ELSE [messagesSent EXCEPT ![i][j][index] = messagesSent[i][j][index] + 1 ]
       /\ Send(msg)
    /\ UNCHANGED <<reconfigurationVars, commitsNotified, serverVars, candidateVars, leaderVars, logVars>>

\* Candidate i transitions to leader.
BecomeLeader(i) ==
    /\ state[i] = Candidate
    \* To become leader, the candidate must have received votes from a majority in each active configuration
    /\ \A c \in DOMAIN configurations[i] : votesGranted[i] \in Quorums[configurations[i][c]]
    /\ state'      = [state EXCEPT ![i] = Leader]
    /\ nextIndex'  = [nextIndex EXCEPT ![i] =
                         [j \in Servers |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                         [j \in Servers |-> 0]]
    \* CCF: We reset our own log to its committable subsequence, throwing out
    \* all unsigned log entries of the previous leader.
    /\ LET new_max_index == MaxCommittableIndex(log[i])
           \* The new max config index either depends on the max configuration index in the log
           \*   or is 1 if we only keep the current config (i.e., if there is no config chage in the log)
           new_conf_index == Max({c \in DOMAIN configurations[i] : c <= new_max_index})
       IN
        /\ log' = [log EXCEPT ![i] = SubSeq(log[i],1,new_max_index)]
        \* Potentially also shorten the currentConfiguration if the removed index contained a configuration
        /\ configurations' = [configurations EXCEPT ![i] = RestrictPred(@, LAMBDA c : c <= new_conf_index)]
    /\ UNCHANGED <<reconfigurationCount, removedFromConfiguration, messageVars, currentTerm, votedFor,
        votesRequested, candidateVars, commitIndex, clientRequests, committedLog>>

\* Leader i receives a client request to add v to the log.
ClientRequest(i) ==
    \* Limit number of client requests
    /\ InRequestLimit
    \* Only leaders receive client requests
    /\ state[i] = Leader
    /\ LET entry == [term  |-> currentTerm[i],
                     value |-> clientRequests,
              contentType  |-> TypeEntry]
           newLog == Append(log[i], entry)
       IN  /\ log' = [log EXCEPT ![i] = newLog]
           \* Make sure that each request is unique, reduce state space to be explored
           /\ clientRequests' = clientRequests + 1
    /\ UNCHANGED <<reconfigurationVars, messageVars, serverVars, candidateVars,
                   leaderVars, commitIndex, committedLog>>

\* CCF extension: Signed commits
\* In CCF, the leader periodically signs the latest log prefix. Only these signatures are committable in CCF.
\* We model this via special ``TypeSignature`` log entries and ensure that the commitIndex can only be moved to these special entries.

\* Leader i signs the previous messages in its log to make them committable
\* This is done as a separate entry in the log that has a different
\* message contentType than messages entered by the client.
SignCommittableMessages(i) ==
    /\ LET
        log_len == Len(log[i])
       IN
        \* Only applicable to Leaders with a log that contains at least one message
        /\ state[i] = Leader
        /\ log_len > 0
        \* Make sure the leader does not create two signatures in a row
        /\ log[i][log_len].contentType /= TypeSignature
        /\ LET
            \* Create a new entry in the log that has the contentType Signature and append it
            entry == [term  |-> currentTerm[i],
                      value |-> Nil,
               contentType  |-> TypeSignature]
            newLog == Append(log[i], entry)
            IN log' = [log EXCEPT ![i] = newLog]
        /\ UNCHANGED <<reconfigurationVars, messageVars, serverVars, candidateVars, clientRequests,
                    leaderVars, commitIndex, committedLog>>

\* CCF extension: Reconfiguration of servers
\* In the TLA+ model, a reconfiguration is initiated by the Leader which appends an arbitrary new configuration to its own log.
\* This also triggers a change in the Configurations variable which keeps track of all running configurations.
\* In the following, this Configurations variable is then checked to calculate a quorum and to check which nodes should be contacted or received messages from.

\* Leader can propose a change in the current configuration.
\* This will switch the current set of servers to the proposed set, ONCE BOTH
\* sets of servers have committed this message (in the adjusted configuration
\* this means waiting for the signature to be committed)
ChangeConfiguration(i, newConfiguration) ==
    \* Only leader can propose changes
    /\ state[i] = Leader
    \* Limit reconfigurations
    /\ IsInConfigurations(i, newConfiguration)
    \* Configuration is non empty
    /\ newConfiguration /= {}
    \* Configuration is a proper subset of the Servers
    /\ newConfiguration \subseteq Servers
    \* Configuration is not equal to current configuration
    /\ newConfiguration /= CurrentConfiguration(i)
    \* Keep track of running reconfigurations to limit state space
    /\ reconfigurationCount' = reconfigurationCount + 1
    /\ removedFromConfiguration' = removedFromConfiguration \cup (CurrentConfiguration(i) \ newConfiguration)
    /\ LET
           entry == [term |-> currentTerm[i],
                    value |-> newConfiguration,
                    contentType |-> TypeReconfiguration]
           newLog == Append(log[i], entry)
           IN
           /\ log' = [log EXCEPT ![i] = newLog]
           /\ configurations' = [configurations EXCEPT ![i] = @ @@ Len(log[i]) + 1 :> newConfiguration]
    /\ UNCHANGED <<messageVars, serverVars, candidateVars, clientRequests,
                    leaderVars, commitIndex, committedLog>>


\* Leader i advances its commitIndex to the next possible Index.
\* This is done as a separate step from handling AppendEntries responses,
\* in part to minimize atomic regions, and in part so that leaders of
\* single-server clusters are able to mark entries committed.
\* In CCF and with reconfiguration, the following limitations apply:
\*  - An index can only be committed if it is agreed upon by a Quorum in the
\*    old AND in the new configuration. This means that for any given index,
\*    all configurations of at least that index need to have a quorum of
\*    servers agree on the index before it can be seen as committed.
AdvanceCommitIndex(i) ==
    /\ state[i] = Leader
    /\ LET
        \* We want to get the smallest such index forward that is a signature
        \* This index must be from the current term, 
        \* as explained by Figure 8 and Section 5.4.2 of https://raft.github.io/raft.pdf
        new_index == SelectInSubSeq(log[i], commitIndex[i]+1, Len(log[i]),
            LAMBDA e : e.contentType = TypeSignature /\ e.term = currentTerm[i])
        new_log ==
            IF new_index > 1 THEN
               [ j \in 1..new_index |-> log[i][j] ]
            ELSE
                  << >>
        new_config_index    == NextConfigurationIndex(i)
        IN
        /\  \* Select those configs that need to have a quorum to agree on this leader
            \A config \in {c \in DOMAIN(configurations[i]) : new_index >= c } :
                \* In all of these configs, we now need a quorum in the servers that have the correct matchIndex
                LET config_servers == configurations[i][config]
                    required_quorum == Quorums[config_servers]
                    agree_servers == {k \in config_servers : matchIndex[i][k] >= new_index}
                IN (IF i \in config_servers THEN {i} ELSE {}) \cup agree_servers \in required_quorum
         \* only advance if necessary (this is basically a sanity check after the Min above)
        /\ commitIndex[i] < new_index
        /\ commitIndex' = [commitIndex EXCEPT ![i] = new_index]
        /\ committedLog' = IF new_index > committedLog.index THEN [ node |-> i, index |-> new_index ] ELSE committedLog
        \* If commit index surpasses the next configuration, pop the first config, and eventually retire as leader
        /\ IF /\ Cardinality(DOMAIN configurations[i]) > 1
              /\ new_index >= NextConfigurationIndex(i)
           THEN
              /\ configurations' = [configurations EXCEPT ![i] = RestrictPred(configurations[i], LAMBDA c : c >= new_config_index)]
              \* Get the set of relevant servers of all configurations after the first
              /\ IF /\ \A c \in DOMAIN (configurations[i]) \ {CurrentConfigurationIndex(i)} :
                        new_index >= c => i \notin configurations[i][c]
                 \* Retire if i is not in next configuration anymore
                 THEN /\ state' = [state EXCEPT ![i] = RetiredLeader]
                      /\ UNCHANGED << currentTerm, votedFor, reconfigurationCount, removedFromConfiguration >>
                 \* Otherwise, states remain unchanged
                 ELSE UNCHANGED <<serverVars, reconfigurationCount, removedFromConfiguration>>
           \* Otherwise, Configuration and states remain unchanged
           ELSE UNCHANGED <<serverVars, reconfigurationVars>>
    /\ UNCHANGED <<messageVars, candidateVars, leaderVars, log, clientRequests>>

\* CCF reconfiguration change:
\*  RetiredLeader server i notifies the current commit level to server j
\*  This allows to retire gracefully instead of deadlocking the system through removing itself from the network.
NotifyCommit(i,j) ==
    \* Only RetiredLeader servers send these commit messages
    /\ state[i] = RetiredLeader
    \* Only send notifications of commit to servers in the server set
    /\ IsInServerSetForIndex(j, i, commitIndex[i])
    /\ \/ commitsNotified[i][1] < commitIndex[i]
       \/ InCommitNotificationLimit(i)
    /\ LET new_notified == IF commitsNotified[i][1] = commitIndex[i]
                           THEN <<commitsNotified[i][1], commitsNotified[i][2] + 1>>
                           ELSE <<commitIndex[i], 1>>
       IN  commitsNotified' = [commitsNotified EXCEPT ![i] = new_notified]
    /\ LET msg == [mtype          |-> NotifyCommitMessage,
                   mcommitIndex   |-> commitIndex[i],
                   mterm          |-> currentTerm[i],
                   msource        |-> i,
                   mdest          |-> j]
       IN Send(msg)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, serverVars, candidateVars, leaderVars, logVars >>

\* CCF supports checkQuorum which enables a leader to choose to abdicate leadership.
CheckQuorum(i) ==
    /\ state[i] = Leader
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<reconfigurationVars, messageVars, currentTerm, votedFor, candidateVars, leaderVars, logVars>>

----
\* Message handlers
\* i = recipient, j = sender, m = message

\* Server i receives a RequestVote request from server j with
\* m.mterm <= currentTerm[i].
HandleRequestVoteRequest(i, j, m) ==
    LET logOk == \/ m.mlastLogTerm > MaxCommittableTerm(log[i])
                 \/ /\ m.mlastLogTerm = MaxCommittableTerm(log[i])
                    \* CCF change: Log is only okay up to signatures,
                    \*  not any message in the log
                    /\ m.mlastLogIndex >= MaxCommittableIndex(log[i])
        grant == /\ m.mterm = currentTerm[i]
                 /\ logOk
                 /\ votedFor[i] \in {Nil, j}
    IN /\ m.mterm <= currentTerm[i]
       /\ \/ grant  /\ votedFor' = [votedFor EXCEPT ![i] = j]
          \/ ~grant /\ UNCHANGED votedFor
       /\ Reply([mtype        |-> RequestVoteResponse,
                 mterm        |-> currentTerm[i],
                 mvoteGranted |-> grant,
                 msource      |-> i,
                 mdest        |-> j],
                 m)
       /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, state, currentTerm, candidateVars, leaderVars, logVars>>

\* Server i receives a RequestVote response from server j with
\* m.mterm = currentTerm[i].
HandleRequestVoteResponse(i, j, m) ==
    \* This tallies votes even when the current state is not Candidate, but
    \* they won't be looked at, so it doesn't matter.
    \* It also tallies votes from servers that are not in the configuration but that is filtered out in BecomeLeader
    /\ m.mterm = currentTerm[i]
    /\ \/ /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] =
                                  votesGranted[i] \cup {j}]
       \/ /\ ~m.mvoteGranted
          /\ UNCHANGED votesGranted
    /\ Discard(m)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, serverVars, votedFor, votesRequested, leaderVars, logVars>>

\* Server i receives a RequestVote request from server j with
\* m.mterm < currentTerm[i].
RejectAppendEntriesRequest(i, j, m, logOk) ==
    /\ \/ m.mterm < currentTerm[i]
       \/ /\ m.mterm = currentTerm[i]
          /\ state[i] = Follower
          /\ \lnot logOk
    /\ Reply([mtype           |-> AppendEntriesResponse,
              mterm           |-> currentTerm[i],
              msuccess        |-> FALSE,
              mmatchIndex     |-> 0,
              msource         |-> i,
              mdest           |-> j],
              m)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, serverVars, logVars>>

ReturnToFollowerState(i, m) ==
    /\ m.mterm = currentTerm[i]
    /\ state[i] = Candidate
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, currentTerm, votedFor, logVars, messages>>

AppendEntriesAlreadyDone(i, j, index, m) ==
    /\ \/ m.mentries = << >>
       \/ /\ m.mentries /= << >>
          /\ Len(log[i]) >= index
          /\ log[i][index].term = m.mentries[1].term
    \* In normal Raft, this could make our commitIndex decrease (for
    \* example if we process an old, duplicated request).
    \* In CCF however, messages are encrypted and integrity protected
    \* which also prevents message replays and duplications.
    \* Note, though, that [][\A i \in Servers : commitIndex[i]' >= commitIndex[i]]_vars is not a theorem of the specification.
    /\ commitIndex' = [commitIndex EXCEPT ![i] = m.mcommitIndex]
    /\ Reply([mtype           |-> AppendEntriesResponse,
              mterm           |-> currentTerm[i],
              msuccess        |-> TRUE,
              mmatchIndex     |-> m.mprevLogIndex + Len(m.mentries),
              msource         |-> i,
              mdest           |-> j],
              m)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, serverVars, log, clientRequests, committedLog>>

ConflictAppendEntriesRequest(i, index, m) ==
    /\ m.mentries /= << >>
    /\ Len(log[i]) >= index
    /\ log[i][index].term /= m.mentries[1].term
    /\ LET new_log == [index2 \in 1..(Len(log[i]) - 1) |-> log[i][index2]]
           new_conf_index == Max({c \in DOMAIN configurations[i] : c < index})
       IN /\ log' = [log EXCEPT ![i] = new_log]
        \* Potentially also shorten the currentConfiguration if the removed index contained a configuration
          /\ configurations' = [configurations EXCEPT ![i] = RestrictPred(@, LAMBDA c : c <= new_conf_index)]
    \* On conflicts, we shorten the log. This means we also want to reset the
    \*  sent messages that we track to limit the state space
    /\ LET newCounts == [j \in Servers
                |-> [n \in 1..min(Len(messagesSent[i][j]) - 1, index - 1)
                |-> messagesSent[i][j][n]]]
       IN messagesSent' = [messagesSent EXCEPT ![i] = newCounts ]
    /\ UNCHANGED <<reconfigurationCount, removedFromConfiguration, serverVars, commitIndex, messages, commitsNotified, clientRequests, committedLog>>

NoConflictAppendEntriesRequest(i, j, m) ==
    /\ m.mentries /= << >>
    /\ Len(log[i]) = m.mprevLogIndex
    /\ log' = [log EXCEPT ![i] = Append(log[i], m.mentries[1])]
    \* If this is a reconfiguration, update Configuration list
    \* Also, if the commitIndex is updated, we may pop an old config at the same time
    /\ LET
        have_added_config   == m.mentries[1].contentType = TypeReconfiguration
        added_config        == IF have_added_config
                               THEN m.mprevLogIndex + 1 :> m.mentries[1].value
                               ELSE << >>
        new_commit_index    == max(m.mcommitIndex, commitIndex[i])
        new_config_index    == NextConfigurationIndex(i)
        \* A config can be removed if the new commit index reaches at least the next config index.
        \* This happens either on configs that are already in the currentConfiguration list or on new configs that
        \* are already committed.
        have_removed_config == IF Cardinality(DOMAIN configurations[i]) > 1
                               THEN new_commit_index >= new_config_index
                               ELSE IF have_added_config
                                    THEN new_commit_index >= m.mprevLogIndex + 1
                                    ELSE FALSE
        base_config         == IF have_removed_config
                               THEN IF Cardinality(DOMAIN configurations[i]) > 1
                                    THEN RestrictPred(configurations[i], LAMBDA c : c >= new_config_index)
                                    ELSE << >>
                               ELSE configurations[i]
        new_config          == IF have_added_config
                               THEN base_config @@ added_config
                               ELSE base_config
        IN
        /\ commitIndex' = [commitIndex EXCEPT ![i] = new_commit_index]
        /\ configurations' = [configurations EXCEPT  ![i] = new_config]
        \* If we added a new configuration that we are in and were pending, we are now follower
        /\ IF /\ state[i] = Pending
              /\ \E conf_index \in DOMAIN(new_config) : i \in new_config[conf_index]
           THEN state' = [state EXCEPT ![i] = Follower ]
           ELSE UNCHANGED state
    /\ Reply([mtype           |-> AppendEntriesResponse,
              mterm           |-> currentTerm[i],
              msuccess        |-> TRUE,
              mmatchIndex     |-> m.mprevLogIndex + Len(m.mentries),
              msource         |-> i,
              mdest           |-> j],
              m)
    /\ UNCHANGED <<reconfigurationCount, removedFromConfiguration, messagesSent, commitsNotified, currentTerm, votedFor, clientRequests, committedLog>>

AcceptAppendEntriesRequest(i, j, logOk, m) ==
    \* accept request
    /\ m.mterm = currentTerm[i]
    /\ state[i] \in {Follower, Pending}
    /\ logOk
    /\ LET index == m.mprevLogIndex + 1
       IN \/ AppendEntriesAlreadyDone(i, j, index, m)
          \/ ConflictAppendEntriesRequest(i, index, m)
          \/ NoConflictAppendEntriesRequest(i, j, m)

\* Server i receives an AppendEntries request from server j with
\* m.mterm <= currentTerm[i]. This just handles m.entries of length 0 or 1, but
\* implementations could safely accept more by treating them the same as
\* multiple independent requests of 1 entry.
HandleAppendEntriesRequest(i, j, m) ==
    LET logOk == \/ m.mprevLogIndex = 0
                 \/ /\ m.mprevLogIndex > 0
                    /\ m.mprevLogIndex <= Len(log[i])
                    /\ m.mprevLogTerm = log[i][m.mprevLogIndex].term
    IN /\ m.mterm <= currentTerm[i]
       /\ \/ RejectAppendEntriesRequest(i, j, m, logOk)
          \/ ReturnToFollowerState(i, m)
          \/ AcceptAppendEntriesRequest(i, j, logOk, m)
       /\ UNCHANGED <<candidateVars, leaderVars>>

\* Server i receives an AppendEntries response from server j with
\* m.mterm = currentTerm[i].
HandleAppendEntriesResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ \/ /\ m.msuccess \* successful
          /\ nextIndex'  = [nextIndex  EXCEPT ![i][j] = m.mmatchIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mmatchIndex]
       \/ /\ \lnot m.msuccess \* not successful
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
                               Max({nextIndex[i][j] - 1, 1})]
          /\ UNCHANGED matchIndex
    /\ Discard(m)
    /\ UNCHANGED <<reconfigurationVars, messagesSent, commitsNotified, serverVars, candidateVars, logVars>>

\* Any RPC with a newer term causes the recipient to advance its term first.
UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm'    = [currentTerm EXCEPT ![i] = m.mterm]
    /\ state'          = [state       EXCEPT ![i] = IF @ \in {Leader, Candidate} THEN Follower ELSE @]
    /\ votedFor'       = [votedFor    EXCEPT ![i] = Nil]
       \* messages is unchanged so m can be processed further.
    /\ UNCHANGED <<reconfigurationVars, messageVars, candidateVars, leaderVars, logVars>>

\* Responses with stale terms are ignored.
DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<reconfigurationVars, serverVars, messagesSent, commitsNotified, candidateVars, leaderVars, logVars>>

\* Drop messages if they are irrelevant to the node
DropIgnoredMessage(i,j,m) ==
    \* Drop messages if...
    /\
       \* .. recipient is still Pending..
       \/ /\ state[i] = Pending
          \* .. and the message is anything other than an append entries request
          /\ m.mtype /= AppendEntriesRequest
       \*  OR if message is to a server that has surpassed the Pending stage ..
       \/ /\ state[i] /= Pending
        \* .. and it comes from a server outside of the configuration
          /\ \lnot IsInServerSet(j, i)
       \*  OR if recipient is RetiredLeader and this is not a request to vote
       \/ /\ state[i] = RetiredLeader
          /\ m.mtype /= RequestVoteRequest
    /\ Discard(m)
    /\ UNCHANGED <<reconfigurationVars, serverVars, messagesSent, commitsNotified, candidateVars, leaderVars, logVars>>

\* RetiredLeader leaders send notify commit messages to update all nodes about the commit level
UpdateCommitIndex(i,j,m) ==
    /\ m.mcommitIndex > commitIndex[i]
    /\ LET
        new_commit_index    == m.mcommitIndex
        new_config_index    == NextConfigurationIndex(i)
        \* Old config can be dropped when we reach the index of the next config
        can_drop_config == IF Cardinality(DOMAIN configurations[i]) > 1
                           THEN new_commit_index >= new_config_index
                           ELSE FALSE
        new_config      == IF can_drop_config
                           THEN RestrictPred(configurations[i], LAMBDA c : c >= new_config_index)
                           ELSE configurations[i]
        IN
        /\ commitIndex' = [commitIndex EXCEPT ![i] = new_commit_index]
        /\ configurations' = [configurations EXCEPT ![i] = new_config]
    /\ UNCHANGED <<reconfigurationCount, messages, messagesSent, commitsNotified, currentTerm,
                   votedFor, candidateVars, leaderVars, log, clientRequests, committedLog>>

\* Receive a message.

RcvDropIgnoredMessage ==
    \* Drop any message that are to be ignored by the recipient
    \E m \in messages : DropIgnoredMessage(m.mdest,m.msource,m)

RcvUpdateTerm ==
    \* Any RPC with a newer term causes the recipient to advance
    \* its term first. Responses with stale terms are ignored.
    \E m \in messages : UpdateTerm(m.mdest, m.msource, m)

RcvRequestVoteRequest ==
    \E m \in messages : 
        /\ m.mtype = RequestVoteRequest
        /\ HandleRequestVoteRequest(m.mdest, m.msource, m)

RcvRequestVoteResponse ==
    \E m \in messages : 
        /\ m.mtype = RequestVoteResponse
        /\ \/ HandleRequestVoteResponse(m.mdest, m.msource, m)
           \/ DropStaleResponse(m.mdest, m.msource, m)

RcvAppendEntriesRequest ==
    \E m \in messages : 
        /\ m.mtype = AppendEntriesRequest
        /\ HandleAppendEntriesRequest(m.mdest, m.msource, m)

RcvAppendEntriesResponse ==
    \E m \in messages : 
        /\ m.mtype = AppendEntriesResponse
        /\ \/ HandleAppendEntriesResponse(m.mdest, m.msource, m)
           \/ DropStaleResponse(m.mdest, m.msource, m)

RcvUpdateCommitIndex ==
    \E m \in messages : 
        /\ m.mtype = NotifyCommitMessage
        /\ UpdateCommitIndex(m.mdest, m.msource, m)
        /\ Discard(m)

Receive ==
    \/ RcvDropIgnoredMessage
    \/ RcvUpdateTerm
    \/ RcvRequestVoteRequest
    \/ RcvRequestVoteResponse
    \/ RcvAppendEntriesRequest
    \/ RcvAppendEntriesResponse
    \/ RcvUpdateCommitIndex

\* End of message handlers.
----

\* During the model check, the model checker will search through all possible state transitions.
\* Each of these transitions has additional constraints that have to be fulfilled for the state to be an allowed step.
\* For example, ``BecomeLeader`` is only a possible step if the selected node has enough votes to do so.

\* Defines how the variables may transition.
Next ==
    \/ \E i \in Servers : Timeout(i)
    \/ \E i, j \in Servers : RequestVote(i, j)
    \/ \E i \in Servers : BecomeLeader(i)
    \/ \E i \in Servers : ClientRequest(i)
    \/ \E i \in Servers : SignCommittableMessages(i)
    \/ \E i \in Servers : \E c \in SUBSET(Servers \ removedFromConfiguration) : ChangeConfiguration(i, c)
    \/ \E i, j \in Servers : NotifyCommit(i,j)
    \/ \E i \in Servers : AdvanceCommitIndex(i)
    \/ \E i, j \in Servers : AppendEntries(i, j)
    \/ \E i \in Servers : CheckQuorum(i)
    \/ Receive

\* The specification must start with the initial state and transition according
\* to Next.
Spec == Init /\ [][Next]_vars

----
\* Correctness invariants
\* These invariants should be true for all possible states

\* Committed log entries should not conflict
LogInv ==
    /\ \A i \in Servers : IsPrefix(Committed(i),SubSeq(log[committedLog.node],1,committedLog.index))

\* There should not be more than one leader per term at the same time
\* Note that this does not rule out multiple leaders in the same term at different times
MoreThanOneLeaderInv ==
    \A i,j \in Servers :
        (/\ currentTerm[i] = currentTerm[j]
         /\ state[i] = Leader
         /\ state[j] = Leader)
        => i = j

\* If a candidate has a chance of being elected, there
\* are no log entries with that candidate's term
CandidateTermNotInLogInv ==
    \A i \in Servers :
        (/\ state[i] = Candidate
        /\ \A k \in DOMAIN (configurations[i]) :
            {j \in Servers :
                /\ currentTerm[j] = currentTerm[i]
                /\ votedFor[j] = i
            } \in Quorums[configurations[i][k]]
        )
        =>
        \A j \in Servers :
        \A n \in DOMAIN log[j] :
             log[j][n].term /= currentTerm[i]

\* A leader always has the greatest index for its current term (this does not
\* mean all of its log will survive if it is not committed + signed yet)
ElectionSafetyInv ==
    \A i \in Servers :
        state[i] = Leader =>
        \A j \in Servers : i /= j =>
            LET FilterAndMax(a, b) == 
                    IF a.term = currentTerm[i] THEN max(a.term, b) ELSE b
            IN FoldSeq(FilterAndMax, 0, log[i]) >= FoldSeq(FilterAndMax, 0, log[j])

----
\* Every (index, term) pair determines a log prefix.
\* From page 8 of the Raft paper: "If two logs contain an entry with the same index and term, then the logs are identical in all preceding entries."
LogMatchingInv ==
    \A i, j \in Servers : i /= j =>
        \A n \in 1..min(Len(log[i]), Len(log[j])) :
            log[i][n].term = log[j][n].term =>
            SubSeq(log[i],1,n) = SubSeq(log[j],1,n)
----
\* A leader has all committed entries in its log. This is expressed
\* by LeaderCompleteness below. The inductive invariant for
\* that property is the conjunction of LeaderCompleteness with the
\* other three properties below.

\* All committed entries are contained in the log
\* of at least one server in every quorum
QuorumLogInv ==
    \A i \in Servers :
        \A S \in Quorums[CurrentConfiguration(i)] :
            \E j \in S :
                IsPrefix(Committed(i), log[j])

\* The "up-to-date" check performed by servers
\* before issuing a vote implies that i receives
\* a vote from j only if i has all of j's committed
\* entries
MoreUpToDateCorrectInv ==
    \A i, j \in Servers : i /= j =>
        ((\/ MaxCommittableTerm(log[i]) > MaxCommittableTerm(log[j])
         \/ /\ MaxCommittableTerm(log[i]) = MaxCommittableTerm(log[j])
            /\ MaxCommittableIndex(log[i]) >= MaxCommittableIndex(log[j])) =>
        IsPrefix(Committed(j), log[i]))

\* The committed entries in every log are a prefix of the
\* leader's log up to the leader's term (since a next Leader may already be
\* elected without the old leader stepping down yet)
LeaderCompletenessInv ==
    \A i \in Servers :
        state[i] = Leader =>
        \A j \in Servers : i /= j =>
            IsPrefix(CommittedTermPrefix(j, currentTerm[i]),log[i])

\* In CCF, only signature messages should ever be committed
SignatureInv ==
    \A i \in Servers :
        \/ commitIndex[i] = 0
        \/ log[i][commitIndex[i]].contentType = TypeSignature

\* Helper function for checking the type safety of log entries
LogTypeOK(xlog) ==
    IF Len(xlog) > 0 THEN
        \A k \in 1..Len(xlog) :
            /\ xlog[k].term \in Nat \ {0}
            /\ \/ /\ xlog[k].contentType = TypeEntry
                  /\ xlog[k].value \in Nat \ {0}
               \/ /\ xlog[k].contentType = TypeSignature
                  /\ xlog[k].value = Nil
               \/ /\ xlog[k].contentType = TypeReconfiguration
                  /\ xlog[k].value \subseteq Servers
    ELSE TRUE

ReconfigurationVarsTypeInv ==
    /\ reconfigurationCount \in Nat
    /\ \A i \in Servers : 
        \A c \in DOMAIN configurations[i]:
            configurations[i][c] \subseteq Servers

MessageVarsTypeInv ==
    /\ \A m \in messages :
        /\ m.msource \in Servers
        /\ m.mdest \in Servers
        /\ m.mterm \in Nat \ {0}
        /\ \/ /\ m.mtype = AppendEntriesRequest
                /\ m.mprevLogIndex \in Nat
                /\ m.mprevLogTerm \in Nat
                /\ LogTypeOK(m.mentries)
                /\ m.mcommitIndex \in Nat
            \/ /\ m.mtype = AppendEntriesResponse
                /\ m.msuccess \in BOOLEAN
                /\ m.mmatchIndex \in Nat
            \/ /\ m.mtype = RequestVoteRequest
                /\ m.mlastLogTerm \in Nat
                /\ m.mlastLogIndex \in Nat
            \/ /\ m.mtype = RequestVoteResponse
                /\ m.mvoteGranted \in BOOLEAN
            \/ /\ m.mtype = NotifyCommitMessage
                /\ m.mcommitIndex \in Nat
    /\ \A i,j \in Servers : i /= j =>
        /\ Len(messagesSent[i][j]) \in Nat
        /\ IF Len(messagesSent[i][j]) > 0 THEN
            \A k \in 1..Len(messagesSent[i][j]) :
                messagesSent[i][j][k] \in Nat \ {0}
            ELSE TRUE
    /\ \A i \in Servers :
        /\ commitsNotified[i][1] \in Nat
        /\ commitsNotified[i][2] \in Nat

ServerVarsTypeInv ==
    /\ \A i \in Servers :
        /\ currentTerm[i] \in Nat \ {0}
        /\ state[i] \in States
        /\ votedFor[i] \in {Nil} \cup Servers

CandidateVarsTypeInv ==
    /\ \A i \in Servers :
        /\ votesGranted[i] \subseteq Servers
        /\ \A j \in Servers : i /= j => 
            /\ votesRequested[i][j] \in Nat

LeaderVarsTypeInv ==
    /\ \A i, j \in Servers : i /= j =>
        /\ nextIndex[i][j] \in Nat \ {0}
        /\ matchIndex[i][j] \in Nat

LogVarsTypeInv ==
    /\ \A i \in Servers :
        /\ Len(log[i]) \in Nat
        /\ LogTypeOK(log[i])
        /\ commitIndex[i] \in Nat
    /\ clientRequests \in Nat \ {0}
    /\ committedLog \in [ node: Servers, index: Nat ]

\* Invariant to check the type safety of all variables
TypeInv ==
    /\ ReconfigurationVarsTypeInv
    /\ MessageVarsTypeInv
    /\ ServerVarsTypeInv
    /\ CandidateVarsTypeInv
    /\ LeaderVarsTypeInv
    /\ LogVarsTypeInv

\* Each server's term should be equal to or greater than the terms of messages it has sent
MonoTermInv ==
    \A m \in messages: currentTerm[m.msource] >= m.mterm

\* Terms in logs should be monotonically increasing
MonoLogInv ==
    \A i \in Servers :
        \/ Len(log[i]) = 0
        \/ /\ log[i][Len(log[i])].term <= currentTerm[i]
           /\ \/ Len(log[i]) = 1
              \/ \A k \in 1..Len(log[i])-1 :
                \* Terms in logs should only increase after a signature
                \/ log[i][k].term = log[i][k+1].term
                \/ /\ log[i][k].term < log[i][k+1].term
                   /\ log[i][k].contentType = TypeSignature


LogConfigurationConsistentInv ==
    \A i \in Servers:
        \A k \in DOMAIN (configurations[i]) :
            k # 0 => log[i][k].value = configurations[i][k]

PendingBecomesFollowerProp ==
    \* A pending node that becomes part of any configuration immediately transitions to Follower.
    [][\A s \in { s \in Servers : state[s] = Pending } : 
            s \in GetServerSet(s)' => 
                state[s]' = Follower]_vars

----
\* Debugging invariants
\* These invariants should give error traces and are useful for debugging to see if important situations are possible
\* These invariants are not checked unless specified in the .cfg file

\* This invariant is false with checkQuorum enabled but true with checkQuorum disabled
DebugInvLeaderCannotStepDown ==
    \A m \in messages :
        /\ m.mtype = AppendEntriesRequest
        /\ currentTerm[m.msource] = m.mterm
        => state[m.msource] = Leader

\* This invariant shows that it should be possible for Node 4 or 5 to become leader
\* Note that symmetry for the set of servers should be disabled to check this debug invariant
DebugInvReconfigLeader ==
    /\ state[NodeFour] /= Leader
    /\ state[NodeFive] /= Leader

\* This invariant shows that a txn can be committed after a reconfiguration
DebugInvSuccessfulCommitAfterReconfig ==
    \lnot (
        \E i \in Servers:
            \E k_1,k_2 \in 1..Len(log[i]) :
                /\ k_1 < k_2
                /\ log[i][k_1].contentType = TypeReconfiguration
                /\ log[i][k_2].contentType = TypeEntry
                /\ commitIndex[i] > k_2
    )

\* Check that eventually all messages can be dropped or processed and we did not forget a message
DebugInvAllMessagesProcessable ==
    Len(messages) > 0 ~> Len(messages) = 0

\* The Retirement state is reached by Leaders that remove themselves from the configuration.
\* It should be reachable if a leader is removed.
DebugInvRetirementReachable ==
    \A i \in Servers : state[i] /= RetiredLeader

===============================================================================

\* Changelog:
\* CCF version of TLA model
\* 2021-05:
\* - Removed the following features from the model:
\*   - Restart (In CCF, no restart possible. Crashed nodes will not recover but
\*     will need to be added again in a configuration change.)
\*   - DuplicateMessage (In CCF, message encryption catches duplicated messages
\*     before they are passed on to the Raft protocol level)
\*   - DropMessage disabled (but not removed), due to state explosion we do not
\*     consider this in our model.
\* - Added the following features to the model:
\*   - SignCommittableMessages: In CCF the leader signs the last messages which
\*     only makes them committed after this signature has been committed.
\*   - Reconfiguration of running servers through ChangeConfiguration, added
\*     Retired Leader and Pending states
\*   - NotifyCommit for RetiredLeader to keep notifying of known commitIndex
\*   - Limits on most perpetrators for state explosion
\* - Changed the following behavior:
\*   - Messages are now a set which removes duplicates but simplifies states
\*
\* Original Raft changelog:
\* 2014-12-02:
\* - Fix AppendEntries to only send one entry at a time, as originally
\*   intended. Since SubSeq is inclusive, the upper bound of the range should
\*   have been nextIndex, not nextIndex + 1. Thanks to Igor Kovalenko for
\*   reporting the issue.
\* - Change matchIndex' to matchIndex (without the apostrophe) in
\*   AdvanceCommitIndex. This apostrophe was not intentional and perhaps
\*   confusing, though it makes no practical difference (matchIndex' equals
\*   matchIndex). Thanks to Hugues Evrard for reporting the issue.
\*
\* 2014-07-06:
\* - Version from PhD dissertation
