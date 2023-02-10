# @version ^0.3.7
# no-limit hold'em sit-n-go tournament contract

# TODO: add rake (rewards tabs for progress txns)?

MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

playerAddress: public(HashMap[uint256, address])
pendingPlayerAddress: public(HashMap[uint256, address])

@external
def register(_playerId: uint256):
  assert _playerId != empty(uint256), "invalid playerId"
  assert self.playerAddress[_playerId] == empty(address), "playerId unavailable"
  self.playerAddress[_playerId] = msg.sender

@external
def changePlayerAddress(_playerId: uint256, _newAddress: address):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  if _newAddress == empty(address):
    self.playerAddress[_playerId] = _newAddress
  else:
    self.pendingPlayerAddress[_playerId] = _newAddress

@external
def confirmChangePlayerAddress(_playerId: uint256):
  assert self.pendingPlayerAddress[_playerId] == msg.sender, "unauthorised"
  self.pendingPlayerAddress[_playerId] = empty(address)
  self.playerAddress[_playerId] = msg.sender

# the deck is represented by the numbers 1, ..., 52
# spades (01-13), clubs (14-26), diamonds (27-39), hearts (40-52)

@internal
@pure
def rank(card: uint256) -> uint256:
  return (card - 1) % 13

@internal
@pure
def suit(card: uint256) -> uint256:
  return (card - 1) / 13

# a permutation of the deck is an array uint256[52] of card numbers
# we hash permutations by first converting to Bytes[52] then sha256
# we assume the hash of a permutation is never empty(bytes32)

struct Proof:
  proof: Bytes[52]

# not using enum because arrays are not supported
Req_HIDE:      constant(uint256) = 0
Req_MAY_SHOW:  constant(uint256) = 1
Req_MUST_SHOW: constant(uint256) = 2

struct Hand:
  dealer:      uint256            # seat index of current dealer
  deckIndex:   uint256            # index of next card in deck
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  live:        bool[MAX_SEATS]    # whether this player has a live hand
  actionIndex: uint256            # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player
  revealBlock: uint256            # block from which new revelations were required
  pot:         uint256            # pot for the hand (from previous rounds)

struct Config:
  tableId:     uint256             # table id (can be reused after table is finished)
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  startsWith:  uint256             # game can start when this many players are seated
  untilLeft:   uint256             # game ends when this many players are left
  structure:   uint256[MAX_LEVELS] # small blind levels (right-padded with blanks)
  levelBlocks: uint256             # blocks between levels
  proveBlocks: uint256             # blocks allowed for responding to a challenge
  revBlocks:   uint256             # blocks to meet a revelation requirement
  actBlocks:   uint256             # blocks to act before folding can be triggered

# not using Vyper enum because of this bug https://github.com/vyperlang/vyper/pull/3196/files#r1062141796
#enum Phase:
#  JOIN       # before the game has started, taking seats
#  COMMIT     # players can make commitments, and prove or challenge previous commitments
#               # commitments starts empty, and can increase
#               # openCommits, revelations, and revRequired start possibly non-empty
#               # openCommits are cleared; their revelations and revRequireds stay stale
#               # proofs can come in
#               # when all new commitments are in, this phase can be ended and the above cleared
#  PLAY       # new commitments in, challenges closed, players can reveal cards and play
#               # commitments and revRequired start non-empty, openCommits stays empty
#               # revRequired can increase
#               # revelations come in when needed
#               # proofs stay empty
Phase_JOIN:   constant(uint256) = 0
Phase_COMMIT: constant(uint256) = 1
Phase_PLAY:   constant(uint256) = 2

struct Table:
  config:      Config
  # phase:       Phase
  phase:       uint256
  startBlock:  uint256              # block number when game started
  seats:       uint256[MAX_SEATS]   # playerIds in seats as at the start of the game
  stacks:      uint256[MAX_SEATS]   # stack at each seat (zero for eliminated or all-in players)
  hand:        Hand                 # current Hand
  commitments: bytes32[MAX_SEATS]     # hashed permutations from each player
  revRequired: uint256[26][MAX_SEATS] # whether a revelation is required
  revelations: uint256[26][MAX_SEATS] # revealed cards from the shuffle
  openCommits: bytes32[MAX_SEATS]     # unverified commitments now open to being challenged
  challIndex:  uint256                # index of a player being actively challenged
  challBlock:  uint256                # block when challenge was issued (or empty if no challenge)
  proofs:      Proof[MAX_SEATS]       # proofs of commitments


tables: HashMap[uint256, Table]

@internal
@view
def nextPlayer(_tableId: uint256, _seatIndex: uint256) -> uint256:
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    if nextIndex == self.tables[_tableId].config.startsWith:
      nextIndex = 0
    else:
      nextIndex += 1
    if (self.tables[_tableId].stacks[nextIndex] == empty(uint256) and
        not self.tables[_tableId].hand.live[nextIndex]):
      continue
    else:
      return nextIndex
  assert False, "no live players"
  return nextIndex

@internal
@view
def smallBlind(_tableId: uint256) -> uint256:
  level: uint256 = empty(uint256)
  if (self.tables[_tableId].startBlock +
      MAX_LEVELS * self.tables[_tableId].config.levelBlocks <
      block.number):
    level = ((block.number - self.tables[_tableId].startBlock) /
             self.tables[_tableId].config.levelBlocks)
  else:
    level = MAX_LEVELS - 1
  for _ in range(MAX_LEVELS):
    if self.tables[_tableId].config.structure[level] == empty(uint256):
      level -= 1
    else:
      break
  return self.tables[_tableId].config.structure[level]

@internal
def placeBet(_tableId: uint256, _seatIndex: uint256, _size: uint256):
  amount: uint256 = min(_size, self.tables[_tableId].stacks[_seatIndex])
  self.tables[_tableId].stacks[_seatIndex] -= amount
  self.tables[_tableId].hand.bet[_seatIndex] += amount

@external
def commit(_playerId: uint256, _tableId: uint256, _seatIndex: uint256, _hashed_commitment: bytes32):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  # assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex" # TODO: unnecessary
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
  assert self.tables[_tableId].commitments[_seatIndex] == empty(bytes32), "already committed"
  self.tables[_tableId].commitments[_seatIndex] = _hashed_commitment

@external
def revealCard(_playerId: uint256, _tableId: uint256, _seatIndex: uint256, _cardIndex: uint256, _reveal: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  # assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex" # TODO: unnecessary
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert _reveal != empty(uint256), "invalid reveal"
  assert _cardIndex < 26, "invalid cardIndex"
  assert self.tables[_tableId].revRequired[_seatIndex][_cardIndex] != Req_HIDE, "reveal not required"
  assert self.tables[_tableId].revelations[_seatIndex][_cardIndex] == empty(uint256), "already revealed"
  # TODO: the next two are unnecessary given the phase
  # assert self.tables[_tableId].openCommits[_seatIndex] == empty(bytes32), "previous commitment open"
  # assert self.tables[_tableId].commitments[_seatIndex] != empty(bytes32), "not committed"
  self.tables[_tableId].revelations[_seatIndex][_cardIndex] = _reveal

@internal
@view
def checkRevelations(_tableId: uint256) -> bool:
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    if (self.tables[_tableId].stacks[seatIndex] == empty(uint256) and
        not self.tables[_tableId].hand.live[seatIndex]):
      continue
    for cardIndex in range(26):
      if (self.tables[_tableId].revRequired[seatIndex][cardIndex] != Req_HIDE and
          self.tables[_tableId].revelations[seatIndex][cardIndex] == empty(uint256)):
        return False
  return True

@internal
@view
def revealedCard(_tableId: uint256, _cardIndex: uint256) -> uint256:
  cardIndex: uint256 = _cardIndex
  seatIndex: uint256 = 0
  for stack in self.tables[_tableId].stacks:
    if stack != empty(uint256) or self.tables[_tableId].hand.live[seatIndex]:
      # TODO: unnecessary if this function is only called in correct phase. also subtraction will catch it.
      # assert self.tables[_tableId].revelations[seatIndex][cardIndex] != empty(uint256), "not revealed"
      cardIndex = self.tables[_tableId].revelations[seatIndex][cardIndex] - 1
    seatIndex += 1
  return cardIndex + 1

@internal
@view
def checkProof(_tableId: uint256) -> bool:
  challIndex: uint256 = self.tables[_tableId].challIndex
  if (sha256(self.tables[_tableId].proofs[challIndex].proof) !=
      self.tables[_tableId].openCommits[challIndex]):
    return False
  used: uint256 = 2**52 - 1
  for i in range(52):
    card: uint256 = convert(slice(self.tables[_tableId].proofs[challIndex].proof, i, 1), uint256)
    if (i < 26 and
        self.tables[_tableId].revelations[challIndex][i] != empty(uint256) and
        self.tables[_tableId].revelations[challIndex][i] != card):
      return False
    used &= ~shift(1, convert(card - 1, int128))
  return used == 0

@internal
def failChallenge(_tableId: uint256):
  challIndex: uint256 = self.tables[_tableId].challIndex
  perPlayer: uint256 = self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn
  # burn the offender's bond + buyIn
  send(empty(address), perPlayer)
  self.tables[_tableId].seats[challIndex] = empty(uint256)
  # refund the others' bonds and buyIns
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256):
      send(self.playerAddress[playerId], perPlayer)
  # delete the game
  self.tables[_tableId] = empty(Table)

@internal
def verifyChallenge(_tableId: uint256):
  if self.checkProof(_tableId):
    self.tables[_tableId].openCommits[self.tables[_tableId].challIndex] = empty(bytes32)
    self.tables[_tableId].challBlock = empty(uint256)
  else:
    self.failChallenge(_tableId)

@external
def prove(_tableId: uint256, _playerId: uint256, _seatIndex: uint256, _proof: Bytes[52]):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].proofs[_seatIndex].proof == empty(Bytes[52]), "already provided"
  self.tables[_tableId].proofs[_seatIndex] = Proof({proof: _proof})
  if self.tables[_tableId].challIndex == _seatIndex:
    self.verifyChallenge(_tableId)

@external
def challenge(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].openCommits[_seatIndex] != empty(bytes32), "no open commitment"
  assert self.tables[_tableId].challBlock == empty(uint256), "ongoing challenge"
  self.tables[_tableId].challBlock = block.number
  self.tables[_tableId].challIndex = _seatIndex
  if self.tables[_tableId].proofs[_seatIndex].proof != empty(Bytes[52]):
    self.verifyChallenge(_tableId)

@external
def challengeTimeout(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
  assert self.tables[_tableId].challBlock != empty(uint256), "no ongoing challenge"
  assert block.number > (self.tables[_tableId].challBlock +
                         self.tables[_tableId].config.proveBlocks), "deadline not passed"
  self.failChallenge(_tableId)

@external
def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].revRequired[_seatIndex][_cardIndex] != Req_HIDE, "reveal not required"
  # assert self.tables[_tableId].hand.revealBlock != empty(uint256), "no ongoing revelations" # TODO: unnecessary?
  assert block.number > (self.tables[_tableId].hand.revealBlock +
                         self.tables[_tableId].config.revBlocks), "deadline not passed"
  assert self.tables[_tableId].revelations[_seatIndex][_cardIndex] == empty(uint256), "already revealed"
  self.tables[_tableId].challIndex = _seatIndex
  self.failChallenge(_tableId)

@external
def endChallengePeriod(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
  assert self.tables[_tableId].challBlock == empty(uint256), "ongoing challenge"
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    if self.tables[_tableId].stacks[seatIndex] == empty(uint256):
      continue
    assert self.tables[_tableId].commitments[seatIndex] != empty(bytes32), "missing commitment"
  self.tables[_tableId].openCommits = empty(bytes32[MAX_SEATS])
  self.tables[_tableId].revRequired = empty(uint256[26][MAX_SEATS])
  self.tables[_tableId].revelations = empty(uint256[26][MAX_SEATS])
  self.tables[_tableId].phase = Phase_PLAY

@external
def __init__():
  pass

@external
@payable
def createTable(_playerId: uint256, _seatIndex: uint256, _config: Config):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert _config.tableId != empty(uint256), "invalid tableId"
  assert self.tables[_config.tableId].config.tableId == empty(uint256), "tableId unavailable"
  assert 1 < _config.startsWith, "invalid startsWith"
  assert _config.startsWith <= MAX_SEATS, "invalid startsWith"
  assert _config.untilLeft < _config.startsWith, "invalid untilLeft"
  assert 0 < _config.untilLeft, "invalid untilLeft"
  assert 0 < _config.structure[0], "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.startsWith, "invalid seatIndex"
  assert msg.value == _config.bond + _config.buyIn, "incorrect bond + buyIn"
  self.tables[_config.tableId].phase = Phase_JOIN
  self.tables[_config.tableId].config = _config
  self.tables[_config.tableId].seats[_seatIndex] = _playerId
  self.tables[_config.tableId].stacks[_seatIndex] = _config.buyIn

@external
@payable
def joinTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(uint256), "seatIndex unavailable"
  assert msg.value == self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn, "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = _playerId
  self.tables[_tableId].stacks[_seatIndex] = self.tables[_tableId].config.buyIn

@external
def leaveTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  self.tables[_tableId].seats[_seatIndex] = empty(uint256)
  self.tables[_tableId].stacks[_seatIndex] = empty(uint256)
  send(msg.sender, self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn)

@external
def startGame(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    assert self.tables[_tableId].seats[seatIndex] != empty(uint256), "not enough players"
    for cardIndex in range(MAX_SEATS):
      if cardIndex == self.tables[_tableId].config.startsWith:
        break
      self.tables[_tableId].revRequired[seatIndex][cardIndex] = Req_MUST_SHOW
  self.tables[_tableId].hand.revealBlock = block.number
  self.tables[_tableId].phase = Phase_COMMIT

@external
def selectDealer(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].startBlock == empty(uint256), "already started"
  highestCard: uint256 = empty(uint256)
  highestCardSeatIndex: uint256 = empty(uint256)
  seatIndex: uint256 = 0
  for playerId in self.tables[_tableId].seats:
    card: uint256 = self.revealedCard(_tableId, seatIndex)
    rankCard: uint256 = self.rank(card)
    rankHighestCard: uint256 = self.rank(highestCard)
    if highestCard == empty(uint256) or rankHighestCard < rankCard or (
         rankHighestCard == rankCard and self.suit(highestCard) < self.suit(card)):
      highestCard = card
      highestCardSeatIndex = seatIndex
    self.tables[_tableId].openCommits[seatIndex] = self.tables[_tableId].commitments[seatIndex]
    seatIndex += 1
  self.tables[_tableId].commitments = empty(bytes32[MAX_SEATS])
  self.tables[_tableId].hand.dealer = highestCardSeatIndex
  self.tables[_tableId].startBlock = block.number
  self.tables[_tableId].phase = Phase_COMMIT

@external
def dealHoleCards(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
  self.tables[_tableId].hand.live = empty(bool[MAX_SEATS])
  self.tables[_tableId].hand.bet = empty(uint256[MAX_SEATS])
  self.tables[_tableId].hand.pot = empty(uint256)
  self.tables[_tableId].hand.deckIndex = 0
  seatIndex: uint256 = self.tables[_tableId].hand.dealer
  for __ in range(2):
    for _ in range(MAX_SEATS):
      seatIndex = self.nextPlayer(_tableId, seatIndex)
      for otherIndex in range(MAX_SEATS):
        if otherIndex == self.tables[_tableId].config.startsWith:
          break
        if self.tables[_tableId].seats[otherIndex] != empty(uint256) and otherIndex != seatIndex:
          self.tables[_tableId].revRequired[otherIndex][self.tables[_tableId].hand.deckIndex] = Req_MUST_SHOW
      self.tables[_tableId].hand.live[seatIndex] = True
      self.tables[_tableId].hand.deckIndex += 1
      if seatIndex == self.tables[_tableId].hand.dealer:
        break
  self.tables[_tableId].hand.revealBlock = block.number
  self.tables[_tableId].hand.actionBlock = empty(uint256)

@external
def postBlinds(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
  assert self.tables[_tableId].hand.board[0] == empty(uint256), "board not empty"
  assert self.tables[_tableId].hand.actionBlock == empty(uint256), "already betting"
  assert self.checkRevelations(_tableId), "required revelations missing"
  seatIndex: uint256 = self.nextPlayer(_tableId, self.tables[_tableId].hand.dealer)
  smallBlind: uint256 = self.smallBlind(_tableId)
  self.placeBet(_tableId, seatIndex, smallBlind)
  seatIndex = self.nextPlayer(_tableId, seatIndex)
  self.placeBet(_tableId, seatIndex, smallBlind + smallBlind)
  seatIndex = self.nextPlayer(_tableId, seatIndex)
  self.tables[_tableId].hand.revealBlock = empty(uint256)
  self.tables[_tableId].hand.actionIndex = seatIndex
  self.tables[_tableId].hand.actionBlock = block.number

@internal
def endTurn(_tableId: uint256, _seatIndex: uint256):
  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, _seatIndex)
  if self.tables[_tableId].hand.actionIndex == self.nextPlayer(_tableId, self.tables[_tableId].hand.actionIndex):
    # actionIndex wins the round as last player standing
    # give the winner the pot
    self.tables[_tableId].stacks[self.tables[_tableId].hand.actionIndex] += self.tables[_tableId].hand.pot
    self.tables[_tableId].hand.pot = 0
    # (eliminate any all-in players -- impossible as only winner left standing)
    # (check if untilLeft is reached -- impossible as nobody was eliminated)
    # progress the dealer
    for seatIndex in range(MAX_SEATS):
      if seatIndex == self.tables[_tableId].config.startsWith:
        break
      self.tables[_tableId].hand.live[seatIndex] = self.tables[_tableId].stacks[seatIndex] > 0
    self.tables[_tableId].hand.dealer = self.nextPlayer(_tableId, self.tables[_tableId].hand.dealer)
    # reshuffle: enter commit phase for next round
    pass # TODO
  else:
    self.tables[_tableId].hand.actionBlock = block.number

@external
def fold(_tableId: uint256, _playerId: uint256, _seatIndex: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
  assert self.tables[_tableId].hand.actionIndex == _seatIndex, "wrong turn"
  # assert self.tables[_tableId].hand.live[_seatIndex], "already folded" # TODO: unnecessary
  self.tables[_tableId].hand.live[_seatIndex] = False
  self.endTurn(_tableId, _seatIndex)

@external
def actTimeout(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
  assert block.number > (self.tables[_tableId].hand.actionBlock +
                         self.tables[_tableId].config.actBlocks), "deadline not passed"
  # assert self.tables[_tableId].hand.live[self.tables[_tableId].hand.actionIndex], "already folded" # TODO: unnecessary
  self.tables[_tableId].hand.live[self.tables[_tableId].hand.actionIndex] = False
  self.endTurn(_tableId, self.tables[_tableId].hand.actionIndex)
