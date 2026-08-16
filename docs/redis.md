# Redis: what the realm keeps there, and the rules that hold it up

Redis is the realm's centre — the place every realmd instance and every game server agrees
through, so that no instance owns anything the others cannot see.

Nothing connects a realm server to a game server any more. They meet here, and only here: a
server publishes itself, takes create and join from its own queue, reports what happens on it as
events, and reads and writes characters directly. That is what makes both sides replaceable —
either can restart, or run several times over, without the other noticing.

**How a character reaches a game.** The realm stages it into redis on join — the read itself is the
mechanism, since the store populates its cache on a miss. The game server then reads it from redis
directly, plays, and writes it back there; a flush worker in whichever realmd notices moves it to
the store of record afterwards. No character ever travels through the realm, which is why the
d2dbs listener is gone.

## Keys

All under a `realmd:` prefix.

| key | what it is | lifetime |
|-|-|-|
| `char:<account>:<name>` | the live character (.d2s bytes) | none — see the durability rules |
| `charver:<account>/<name>` | save counter, bumped on every write | none |
| `dirty` (set) | characters whose stored copy is newer than Postgres | none |
| `charlock:<account>/<name>` | the game holding this character, by id | 300 s, refreshed |
| `gamechars:<gameid>` (set) | which characters a game holds | until the game ends |
| `gamename:<name>` | a create in flight is claiming this name | 30 s backstop |
| `token:seq` | realm-global game-token counter | none |
| `gsq:<gsid>` (list) | create/join waiting for that game server | 30 s |
| `gsreply:<seq>` | the answer to one request, keyed by its seq | 30 s |
| `gsev` (list) | what happened on a server, for any instance to apply | 1 h |
| `gs:<gsid>` | one game server: address, capacity, load | 90 s, refreshed |
| `gs` (set) | which servers exist, for enumeration | none |
| `game:<name>`, `games` | the game records and their index | 6 h backstop |

## Two rules the durability depends on

**Never put a TTL on a character that is dirty.** Redis holds the only copy of a save between the
game writing it and the flush worker moving it to Postgres. An expiry there deletes a player's
progress, and nothing can rebuild it.

**Redis must not evict these keys.** Run it `noeviction`, or give characters their own instance or
database. A default eviction policy under memory pressure is the same loss, arriving quietly.

Both are properties of the deployment, not of this code — the code cannot enforce them, which is
why they are written down here.

## How a save survives

1. The game saves. The bytes go to redis, `charver` is bumped, and the character joins `dirty`.
   The save is acknowledged once redis has it, so a game never waits on Postgres.
2. A flush worker — every realmd runs one, and they do not coordinate — takes a name from `dirty`,
   notes the version, reads the **current** bytes, and writes them to Postgres.
3. It then clears the dirty flag **only if the version has not moved**.

Step 3 is the whole argument. A save landing mid-flush bumps the version, the clear is refused, and
the character stays dirty for the next pass. Crash anywhere and it stays dirty too, so another
instance picks it up — that is the entire recovery story, and there is no journal to replay.

The dirty set holds **names, not saves**. Because a flusher reads whatever is current, two of them
doing the same character both write the newest bytes. Duplicated work is wasted, not wrong, which
is what removes any need for exactly-once delivery, acknowledgements, or ordering. It is why this
is a set and a counter rather than a stream with consumer groups.

Reads come from redis first. Postgres may be a flush behind, and reading it first would hand back a
stale character and undo the player's last session.

**Warming the cache is conditional** (`SET NX`). An unconditional write could put durable bytes over
a newer save that landed while they were being read. It is also why loading needs no lock: everyone
who missed may read, one wins the write, the rest discard.

## Locks, and where a lock is the wrong tool

Ownership is compare-and-swap against an owner id, never a bare flag, and never released with a
plain `DEL` — if a lease lapses and another owner takes the key, a blind delete frees *their* lock.
Every release and refresh checks the owner in the same script that acts on it.

But most of what looks like it needs a lock does not:

- **Minting a token** is `INCR`. Atomic across instances by construction.
- **Claiming a game name** is `SET NX`. The winner is decided by redis, not by a lease.
- **Warming the cache** is `SET NX`, as above.
- **Picking a game server** genuinely is read-modify-write, and the answer there is one `EVAL`
  rather than a lock: a script cannot interleave, so there is no lease to expire, no owner to
  verify, and no deadlock.

A lock is for something a caller must *hold* across steps. A single atomic operation is better
whenever the work fits in one.

## The create race, and why a joiner waits

A game is only recorded once its server accepts the create. Between dispatch and that record
existing, a second client asking for the same name used to be told the name was free, lose the race
at the server, and then be told the game did not exist — having just been told it did.

The name is claimed before dispatch, so the loser learns at once. And a join for a name that is
claimed but not yet recorded **waits briefly** for it instead of answering "does not exist", which
is a lie the client acts on. The wait is bounded and stops as soon as the claim clears.

The claim covers only the dispatch window; once the game is recorded, that record owns the name.

## Redis is required

realmd refuses to start without it, and refuses again if it is configured but does not answer,
saying which. It stopped being one backend among several the moment the realm began coordinating
through it, and every one of those things — characters, seats, tokens, the fleet — fails in a way
that reads as a game bug rather than a missing dependency.

The **durable** store stays a choice: pg for a deployment, fs for one host. Neither carries any
coordination, so requiring postgres would only make local iteration slower for nothing.

## A character belongs to one seat

Two clients presenting the same character are two seats, and the engine refuses the second
outright. The realm now refuses it first, naming the game that holds it, instead of issuing a join
the engine drops in silence while the player watches a loading screen.

The claim is strict — held by anyone, the same game included, is a refusal — which works because
only the JOIN takes it. The creator does not claim its character at create; it sends JOINGAME for
the game it just made, so one seat means one claim.

Releases are the other half: leaving frees that character, the game ending frees whatever it still
held, and the lease frees it if the server holding it dies. Because the engine takes a moment per
departing client to notice a socket has gone, a join **waits briefly** for a character's previous
seat to clear before refusing — otherwise a character carried straight into its next game is
turned away by the one it just left.

## How a game reaches a server, with nothing connecting them

A create goes onto the chosen server's queue and the answer comes back on a key named by the
`seqno` already in the packet header. That seq finally does the job its name implies: over one
socket with one request in flight, "the next reply is mine" was true by construction; through a
queue several instances push to, it is simply false, and matching is the difference between an
answer and somebody else's answer. Instances hold disjoint seq ranges (the instance hash owns the
top half of the number), so they cannot collect each other's replies.

The other direction is not a request at all. A player joining or leaving, and a game ending, are
the server stating something already true with nobody waiting on it, so they go onto one event
list any instance drains — each event taken by exactly one of them. Applying an event is the same
code that used to run on the socket; what changed is which instance runs it.

Sending a reply and reporting an event must not share a "currently servicing" flag. Game events
fire on the engine's tick thread while the queue thread may be mid-request, and a shared flag
routed a departure into a reply key: the realm never learned the player had left, so the character
stayed seated in a game that had ended, and the next join was refused. The seq is passed down from
the request that carries it, and events never look at it.

## What the game server does itself

It reads and writes characters directly, and publishes its own presence — address, capacity, load,
and whether it is full — refreshing it on its own tick and immediately whenever a game starts or
ends. The record belongs to the server, and its TTL is how one that dies leaves without anyone
having to notice.

`full` is the server answering a question its own game count cannot: a finished game holds its
engine memory-pool slot through the reap window, so it can be out of room while the count still
shows space. Only the server knows, so only the server says it.

Its redis connection is a single socket and every command holds a lock over the whole
request/reply cycle. Two threads sharing it without that desyncs the connection: the second caller
reads the first one's reply, and afterwards reads come back empty while writes still appear to
work. That failure looked exactly like a missing character.

## Ports that went away

**6113** (the standalone d2cs listener), **6114** (d2dbs) and **6115** (the game-server control
link) are all gone. MCP was always muxed onto the BNCS port the way real Battle.net does it, so no
client ever dialled 6113 — only our own test harness did. Characters come from redis, so nothing
reaches d2dbs. And create/join, registration and game events all travel the store, so there is
nothing left for a control link to carry.

realmd now binds one client-facing port and a health port. A game server binds none that the realm
uses.

Retiring d2dbs took three attempts, and the first two failed in a way worth remembering: the engine
path dialled the listener BEFORE fetching, and treated a failed dial as "no source". The fetch had
already moved to redis, but was never reached — so removing the listener produced "char fetch
FAILED" with the character sitting readable in the store, which reads exactly like a broken store.
When a component looks like it ignores a change, check whether something upstream gates it.

## More than one realmd

Verified, not assumed: two instances against one redis and one game server, a game created through
one and **joined through the other**, both players in the world together. Each instance sees the
whole fleet, dispatches to all of it, and drains the same event stream.

Accounts, the admin flag, password changes, the BNCS profile and guilds all reach the durable
backend too. They used to go to the filesystem whatever it was set to, on the argument that they
are low-volume and simple — which holds right up until there is more than one instance, at which
point "the file on this pod" is a different answer per pod. Low volume is a reason not to cache
something, not a reason not to share it.

The one thing still read from disk is BNFTP, and that is correct: those files are read-only image
content, identical on every instance.

