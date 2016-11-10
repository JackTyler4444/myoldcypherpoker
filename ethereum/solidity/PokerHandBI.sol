pragma solidity ^0.4.1;
/**
* 
* Manages wagers, verifications, and disbursement for a single CypherPoker hand (round).
*
* (C)opyright 2016
*
* This source code is protected by copyright and distributed under license.
* Please see the root LICENSE file for terms and conditions.
*
*/
contract PokerHandBI { 
    
	using CryptoCards for *;
	using GamePhase for *;
	using PokerBetting for *;
	using PokerHandAnalyzer for *;
	
    
    address public owner; //the contract owner -- must exist in any valid Pokerhand-type contract
    address[] public players; //players, in order of play, who must agree to contract before game play may begin; the last player is the dealer, player 1 (index 0) is small blind, player 2 (index 2) is the big blind
    mapping (address => bool) public agreed; //true for all players who agreed to this contract; only players in "players" struct may agree
    
	uint256 public prime; //shared prime modulus
    uint256 public baseCard; //base or first plaintext card in the deck
    
    address public winner; //address of the contract's winner    
    mapping (address => uint256) public playerBets; //stores cumulative bets per betting round (reset before next)
	mapping (address => uint256) public playerChips; //the players' chips, wallets, or purses on which players draw on to make bets, currently equivalent to the wei value sent to the contract.
    uint256 public pot; //total cumulative pot for hand
    uint public betPosition; //current betting player index (in players array)    
    mapping (address => uint256[52]) public encryptedDeck; //incrementally encrypted decks; deck of players[players.length-1] is the final encrypted deck
    mapping (address => uint256[2]) public privateCards; //encrypted private/hole cards per player
    uint256[5] public publicCards; //selected encrypted public cards
    mapping (address => CryptoCards.Key) public playerKeys; //playerss crypo keypairs
    CryptoCards.SplitCardGroup private analyzeCards; //face/value split cards being used for analysis    
    mapping (address => CryptoCards.Card[]) public playerCards; //final decrypted cards for players (only generated during a challenge)
    uint256[5] public communityCards;  //final decrypted community cards (only generated during a challenge)
    uint256 public highestResult=0; //highest hand rank (only generated during a challenge)
    mapping (address => uint256) public results; //hand ranks per player or numeric score representing actions (1=fold lost, 2=fold win, 3=concede loss, 4=concede win)    
	
    //--- PokerHandAnalyzer required work values BEGIN ---
	
    CryptoCards.Card[5] public workCards; 
    CryptoCards.Card[] public sortedGroup;
    CryptoCards.Card[][] public sortedGroups;
    CryptoCards.Card[][15] public cardGroups;	
	
    //--- PokerHandAnalyzer required work values END ---
    
    /**
     * Phase values:
     * 0 - Agreement (not all players have agreed to contract yet)
     * 1 - Encrypted deck storage (all players have agreed to contract)
     * 2 - Private/hole card selection
	 * 3 - Interim decrypted card storage
     * 4 - Betting
     * 5 - Flop cards selection
     * 6 - Interim flop cards decryption
     * 7 - Betting
     * 8 - Turn card selection
     * 9 - Interim turn card decryption
     * 10 - Betting
     * 11 - River card selection
     * 12 - Interim river card decryption
     * 13 - Betting
     * 14 - Submit keys + declare winner
	 * 15 - Verification (only if challenged)
     * 16 - Game complete
     */
    mapping (address => uint8) public phases;
    
    uint public numItems;
             	
  	function PokerHandBI() {       
		owner = msg.sender;
    }
	
	/**
	 * Initializes the contract
	 * 
	 * @param requiredPlayers The players required to agree to the contract before further interaction is allowed. The first player is considered the 
	 * dealer.
	 * @param primeVal The shared prime modulus on which plaintext card values are based and from which encryption/decryption keys are derived.
	 * @param baseCardVal The value of the base or first card of the plaintext deck. The next 51 ascending quadratic residues modulo primeVal are assumed to
	 * comprise the remainder of the deck (see "getCardIndex" for calculations).
	 *
	 * Gas required ~250000
	 */
	function initialize(address[] requiredPlayers, uint256 primeVal, uint256 baseCardVal) public {
	    if (requiredPlayers.length < 2) {
	        throw;
	    }
	    if (primeVal < 2) {
	        throw;
	    }
	    prime = primeVal;
	    baseCard = baseCardVal;		
        for (uint count=0; count<requiredPlayers.length; count++) {
            players.push(requiredPlayers[count]);
            phases[requiredPlayers[count]] = 0;
			playerChips[requiredPlayers[count]] = 0;
			playerBets[requiredPlayers[count]] = 0;
        }
        pot=0;
        betPosition=1;
	}	
	
	/**
	* Returns a the card index of a supplied value. Card indexes are calculated as offsets of quadratic residues modulo prime (storage) with respect
	* to baseCard. If 0 is returned then the supplied value is not a valid card.
	*
	* Gas required for full (52-card) evaluation ~2600000 (usually less if value is determined before full evaluation)
	*/
	function getCardIndex(uint256 value) private returns (uint256 index) {
		index = 1;
		if (value == baseCard) {
			return;
		}
		index++;
		uint256 baseVal = baseCard;
		uint256 exp = (prime-1)/2;		
		while (index < 53) {
			baseVal++;			
			if (CryptoCards.modExp(baseVal, exp, prime) == 1) {
				if (baseVal == value) {					
					return;
				} else {
					index++;
				}
			}			
		}
		index = 0;
		return;
	}
	
	
	/**
	 * Temporary self-destuct function to remove contract from blockchain during development.
	 */
	function destroy() {		
		selfdestruct(owner); 
	}
   
   /*
   * Returns true if the supplied address is allowed to agree to this contract.
   */
   function allowedToAgree (address player) private returns (bool) {		
        for (uint count=0; count<players.length; count++) {
            if (player==players[count]) {
                return (true);
            }
        }
        return (false);		
    }
    
    /*
	* Sets the "agreed" flag to true for the transaction sender. Only accounts registered during the "initialize"
	* call are allowed to agree.
	*/
	function agreeToContract() public {      		
        if (!allowedToAgree(msg.sender)) {
            throw;
        }
		if (phases[msg.sender] != 0) {
			throw;
		}
		agreed[msg.sender]=true;
        phases[msg.sender]=1; 
    }
    
    /**
     * Returns the number of elements in a non-dynamic, 52-element array by checking the element values. Values must be greater than 1 to be considered to exist.
     * 
     * @param inputArray The non-dynamic storage array to check for length.
     * 
     */
    function arrayLength52(uint256[52] storage inputArray) private returns (uint) {
        for (uint count=0; count<52; count++) {
            if (inputArray[count] < 2) {
                return (count);
            }
        }
    }
    
     /**
     * Returns the number of elements in a non-dynamic, 5-element array by checking the element values. Values must be greater than 1 to be considered to exist.
     * 
     * @param inputArray The non-dynamic storage array to check for length..
     * 
     */
    function arrayLength5(uint256[5] storage inputArray) private returns (uint) {
        for (uint count=0; count<5; count++) {
            if (inputArray[count] < 2) {
                return (count);
            }
        }
    }
    
    /**
     * Returns the number of elements in a non-dynamic, 2-element array by checking the element values. Values must be greater than 1 to be considered to exist.
     * 
     * @param inputArray The non-dynamic storage array to check for length.
     * 
     */
    function arrayLength2(uint256[2] storage inputArray) private returns (uint) {
        for (uint count=0; count<2; count++) {
            if (inputArray[count] < 2) {
                return (count);
            }
        }
    }
    
    /**
     * Clears an array by setting all elements to 1. This value is used in order to preserve storage elements between contract sessions (for reduced costs),
     * and since 1 is not a valid plaintext or encrypted card value.
     * 
     * @param inputArray The non-dynamic storage array clear (reset all elements to 1).
     * @param numElements The total number of pre-allocated elements in the array.
     * 
     */
    function clearArray(uint[] storage inputArray, uint numElements) private {
         for (uint count=0; count<numElements; count++) {
            inputArray[count]=1;
        }
    }
	
	/**
	* Stores up to 52 encrypted cards of a full deck for a player. The player must have been specified during initialization, must have agreed,
	* and must be at phase 1. This function may be invoked multiple times by the same player during the encryption phase if transactions need 
	* to be broken up into smaler units.
	*
	* @param cards The encrypted card values to store. Once 52 cards (and only 52 cards) have been stored the player's phase is updated. 
	*/
	function storeEncryptedDeck(uint256[] cards) {
		 if (agreed[msg.sender] != true) {
           return;
        } 
        if (phases[msg.sender] > 1) {
           return;
        }  
        for (uint8 count=0; count<cards.length; count++) {
            encryptedDeck[msg.sender][arrayLength52(encryptedDeck[msg.sender])] = cards[count];             
        }
        if (arrayLength52(encryptedDeck[msg.sender]) == 52) {
            phases[msg.sender]=2;
        }
		if (arrayLength52(encryptedDeck[msg.sender]) > 52) {
		    //is this possible?
			throw;
		}
	}
    
	/**
	 * Stores up to 2 encrypted private or hole cards for a player. The player must have been specified during initialization, must have agreed,
 	 * and must be at phase 2. This function may be invoked multiple times by the same player during the encryption phase if transactions need 
	 * to be broken up into smaler units.
	 */
    function storePrivateCards(uint256[] cards) {
		/*
        if (agreed[msg.sender] != true) {
           return;
        }
        if (playerPhases.allPlayersAbovePhase(1) == false) {
           return;
        }
        if (cards.length != 2) {
           return;
        }        
        for (uint8 count=0; count<cards.length; count++) {
            privateCards[msg.sender].push(cards[count]);
        }
        if (privateCards[msg.sender].length == 2) {
            playerPhases.setPlayerPhase(msg.sender, playerPhases.getPlayerPhase(msg.sender)+1);
          updatePhases();
        }	
		*/
    }

    /*
	* Stores the public or community card(s) for the hand.
	*/
    function storePublicCard(uint256 card) {   
		/*
        if (agreed[msg.sender] != true) {
           return;
        }
        if (msg.sender != players[0]) {
            //only dealer can set public cards
            return;
        }
        if ((playerPhases.allPlayersAtPhase(5) == false) && 
            (playerPhases.allPlayersAtPhase(8) == false) && 
            (playerPhases.allPlayersAtPhase(11) == false)) {
           return;
        }        
        publicCards.push(card);
        //updates once at 3 cards (flop), 4 cards (turn), and 5 cards (river)
        if (publicCards.length >= 3) {
            for (uint8 count=0; count<players.length; count++) {
                playerPhases.setPlayerPhase(players[count], playerPhases.getPlayerPhase(players[count])+1);
                playerPhases.setPlayerPhase(players[count], playerPhases.getPlayerPhase(players[count])+1); //shortcut decryption storage phase for now
            }
            updatePhases();
            betPos.index=1;
        }	
		*/
	}
    
    /*
	* Stores a play-money player bet in the contract.
	*/
	function storeBet(uint256 betValue)  {		
		 /*
      if (agreed[msg.sender] != true) {
        return;
      }
      if ((playerPhases.allPlayersAtPhase(4) == false) && 
          (playerPhases.allPlayersAtPhase(7) == false) && 
          (playerPhases.allPlayersAtPhase(10) == false) && 
          (playerPhases.allPlayersAtPhase(13) == false)) {
          return;
      } 
     
      if (players.storeBet(playerBets, playerChips, pot, betPos, msg.value)) {
           for (uint8 count=0; count<players.list.length; count++) {
              playerPhases.setPlayerPhase(players.list[count], playerPhases.getPlayerPhase(players.list[count])+1);
          }
          updatePhases();
      }	  
      */
    }
    
    /*
	* Indicates that the transaction sender is folding their hand. Currently this is based on a heads-up model so the contract payout is immediate.
	*/
	function fold() {		
	    /*
        for (uint8 count=0; count<players.list.length; count++) {
            if (players.list[count] == msg.sender) {
                results[msg.sender]=1;
            } else {
                winner=players.list[count];
                results[players.list[count]]=2;
            }
        }
        payWinner();		
        */
    }
    
    
    /*
	* Store the crypto keypair for the transaction sender.
	*/
	function storeKeys(uint256 encKey, uint256 decKey) {  
		/*
        if (agreed[msg.sender] != true) {
			return;
        }
      
        if (playerPhases.allPlayersAtPhase(14) == false) {
            return;
        }        
        playerKeys[msg.sender].encKey=encKey;
        playerKeys[msg.sender].decKey=decKey;
        playerKeys[msg.sender].prime=prime;        
        if (playerKeysSubmitted()) {
            decryptAllCards();
        }      
		*/
    }
    
    /*
    * Decrypts all players' private and public/community cards. All crypto keypairs must be stored by this point.
	*/
    function decryptAllCards()  {   
		/*
        if (handIsComplete()) {
            throw;
        }
         for (uint8 count=0; count<players.length; count++) {
     //       publicCards.decryptCards (playerKeys[players.list[count]]);
            for (uint8 count2=0; count2<players.length; count2++){               
	//		    privateCards[players.list[count2]].decryptCards (playerKeys[players.list[count]]);                
            }
         }
         for (count=0; count<players.length; count++) {
             for (count2=0; count2<privateCards[players[count]].length; count2++) {
                // playerCards[players.list[count]].push(privateCards[players.list[count]][count2]);
            }
         }
         for (count=0; count<publicCards.length; count++) {
             communityCards.push(publicCards[count]);
         }  
		 */
    }
    
	/*
	* Uses the PokerHandAnalyzer library to generate player scores from fully decrypted hands. The best 5 cards
	* are to be selected by the calling process. Indices 0 to 4 are public cards and 5 to 6 are private cards.
	*/
    function generatePlayerScore(uint8 indices) external {  
		 /*
      //  if (indices.length < 5) {
    //        return;
     //   }
        uint256 currentResult=0;
        for (uint8 count=0; count<5; count++) {
            if (count < 4) {
                for (uint8 count2=0; count2<5; count2++) {
                    //if (indices[count2] == ) {
                    //}
                }
            }
        }
        //workCards[count]=;
  //      publicCards.appendCards(privateCards[msg.sender]);
//	    privateCards[msg.sender].splitCardData(analyzeCards);
       // currentResult=phaLib.analyze(analyzeCards.suits, analyzeCards.values);
	    //currentResult=workCards.analyze(analyzeCards.suits, analyzeCards.values);
        results[msg.sender]=currentResult;
         if (highestResult < currentResult) {
            highestResult=currentResult;
            winner=msg.sender;
        }
       
        playerPhases.setPlayerPhase(msg.sender, playerPhases.getPlayerPhase(msg.sender)+1);
        updatePhases();
        */
       // analyzeCards.suits.length=0;
        //analyzeCards.values.length=0;
    }
        
    /*
	* True if all players have committed their encryption/decryption keys.
	*/
    function playerKeysSubmitted() private returns (bool) {		
        for (uint8 count=1; count<players.length; count++) {
            if ((playerKeys[players[count]].prime == 0) || (playerKeys[players[count]].encKey == 0) 
                || (playerKeys[players[count]].decKey == 0)) {
                return (false);
            }
        }
        return (true);		
    }
    
    /*
	* True if hand is complete (i.e. hand results have been established but winner has not yet necesarily paid out).
	*/
	function handIsComplete() internal returns (bool) {		
        for (uint8 count=0; count<players.length; count++) {
            if (results[players[count]] > 0) {
                return (true);
            }
        }
        return (false);		
    }
     
}

/**
* 
* Provides cryptographic services for CypherPoker hand contracts.
*
* (C)opyright 2016
*
* This source code is protected by copyright and distributed under license.
* Please see the root LICENSE file for terms and conditions.
*
* Morden testnet address: 0x07a6864227a8b03943ea4a78e9004726a9548daa
*
*/
library CryptoCards {
    
    /*
	* A standard playing card type.
	*/
	struct Card {
        uint index; //plaintext or encrypted
        uint suit; //1-4
        uint value; //1-13
    }
    
    /*
	* A group of cards.
	*/
	struct CardGroup {
       Card[] cards;
    }
    
    /*
	* Used when grouping suits and values.
	*/
	struct SplitCardGroup {
        uint[] suits;
        uint[] values;
    }
    
    /*
	* A crypto keypair type.
	*/
	struct Key {
        uint256 encKey;
        uint256 decKey;
        uint256 prime;
    }
	
	/*
	* Multiple keypairs.
	*/
	struct Keys {
        Key[] keys;
    }
    
    /*
	* Decrypt a group of cards using multiple supplied crypto keypairs.
	*/
	function decryptCards (CardGroup storage self, Keys storage mKeys) {
        uint cardIndex;
		for (uint8 keyCount=0; keyCount<mKeys.keys.length; keyCount++) {
			Key keyRef=mKeys.keys[keyCount];
			for (uint8 count=0; count<self.cards.length; count++) {            
				cardIndex=modExp(self.cards[count].index, keyRef.decKey, keyRef.prime);
				//store first card index, then suit=(((startingIndex-cardIndex-2) / 13) + 1)   value=(((startingIndex-cardIndex-2) % 13) + 1)
				self.cards[count]=Card(cardIndex, (((cardIndex-2) / 13) + 1), (((cardIndex-2) % 13) + 1));
			}
		}
    }
	
	
	/**
	* Performs an arbitrary-size modular exponentiation calculation.
	*/
	function modExp(uint256 base, uint256 exp, uint256 mod) internal returns (uint256 result)  {
		result = 1;
		for (uint count = 1; count <= exp; count *= 2) {
			if (exp & count != 0)
				result = mulmod(result, base, mod);
			base = mulmod(base, base, mod);
		}
	}	
    
    /**
     * Adjust indexes after final decryption if card indexes need to start at 0.
     */
    function adjustIndexes(Card[] storage self) {
        for (uint8 count=0; count<self.length; count++) {
            self[count].index-=2;
        }
    }
   
    /*
	* Appends card from one deck to another.
	*/
	function appendCards (CardGroup storage self, CardGroup storage targetRef) {
        for (uint8 count=0; count<self.cards.length; count++) {
            targetRef.cards.push(self.cards[count]);
        }
    }
  
    /*
	* Splits cards from a deck into sequantial suits and values.
	*/
	function splitCardData (CardGroup storage self, SplitCardGroup storage targetRef) {
         for (uint8 count=0; count<self.cards.length; count++) {
             targetRef.suits.push(self.cards[count].suit);
             targetRef.values.push(self.cards[count].value);
         }
    }
}

/**
* 
* Game phase tracking library for CypherPoker.
*
* (C)opyright 2016
*
* This source code is protected by copyright and distributed under license.
* Please see the root LICENSE file for terms and conditions.
*
* Morden testnet address: 0xbd9ebebb7d9a6c184eaea92c50d0295539415452
*
*/
library GamePhase {
    
    /*
	* A player phase structure.
	*/
	struct Phase {
        address player;
        uint8 phaseNum;
    }
	/*
	* Phases mapped to players.
	*/
    struct PhasesMap {
        Phase[] phases;
    }
    
    /*
	* Sets the phase for a specified player (address) in a referenced contract.
	*/
	function setPlayerPhase(PhasesMap storage self, address player, uint8 phaseNum)  {
        for (uint8 count=0; count<self.phases.length; count++) {
            if (self.phases[count].player == player) {
                self.phases[count].phaseNum = phaseNum;
                return;
            }
        }
    }
    
    /*
	* Retrieves the phase value currently stored for a player in a referenced contract.
	*/
	function getPlayerPhase(PhasesMap storage self, address player) returns (uint8) {
        for (uint8 count=0; count<self.phases.length; count++) {
            if (self.phases[count].player == player) {
                return (self.phases[count].phaseNum);
            }
        }
    }
   
    /*
	* True if all players are at a specific phase in a referenced contract.
	*/
	function allPlayersAtPhase(PhasesMap storage self, uint8 phaseNum) returns (bool) {
        if (self.phases.length == 0) {
            return (false);
        }
        for (uint8 count=0; count<self.phases.length; count++) {
            if (self.phases[count].phaseNum != phaseNum) {
                return (false);
            }
        }
        return (true);
    }
   
     /*
	* True if all players are above a specific phase in a referenced contract.
	*/
	function allPlayersAbovePhase(PhasesMap storage self, uint8 phaseNum) returns (bool) {
        if (self.phases.length == 0) {
            return (false);
        }
        for (uint8 count=0; count<self.phases.length; count++) {
            if (self.phases[count].phaseNum <= phaseNum) {
                return (false);
            }
        }
        return (true);
    }    
}

/**
* 
* Provides cryptographic services for CypherPoker hand contracts.
*
* (C)opyright 2016
*
* This source code is protected by copyright and distributed under license.
* Please see the root LICENSE file for terms and conditions.
*
* Morden testnet address: 0xc5c51c3d248cba19813292c5c5089b8413e75a50
*
*/
library PokerBetting {
    
     struct playersType {address[] list;} //players mapped by addresses
     struct betsType {mapping (address => uint256) bet;} //total bets mapped by player addresses.
	 struct chipsType {mapping (address => uint256) chips;} //player chips remaining, mapped by player addresses.
     struct potType {uint256 value;} //current hand pot, in wei
     struct positionType {uint index;} //current betting position
    
     /*
	 * Stores a bet for a player in a referenced contract.
	 */
	 function storeBet(playersType storage self, 
                       betsType storage betsRef, 
					   chipsType storage chipsRef,
                       potType storage potRef, 
                       positionType storage positionRef, 
                       uint256 betVal) 
                        returns (bool updatePhase) {
	  updatePhase=false;
	  if (chipsRef.chips[msg.sender] < betVal) {
		  //not enough chips available
		  return (updatePhase);
	  }
      betsRef.bet[msg.sender]+=betVal;
	  chipsRef.chips[msg.sender]-=betVal;
      potRef.value+=betVal;
      positionRef.index=(positionRef.index + 1) % self.list.length;      
	  updatePhase=true;
      return (updatePhase);
    }
    
    /*
	* Resets all players' bets in a referenced contract to 0.
	*/
	function resetBets(playersType storage self, betsType storage betsRef) {
        for (uint8 count=0; count<self.list.length; count++) {
            betsRef.bet[self.list[count]] = 0;
        } 
    }
    
    /*
	* True if all players in a referenced contract have placed equal bets.
	*/
	function playerBetsEqual(playersType storage self, betsType storage betsRef) returns (bool) {
        //update must take into account 0 bets (check/call)!
        uint256 betVal=betsRef.bet[self.list[0]];
        if (betVal==0) {
            return (false);
        }
        for (uint8 count=1; count<self.list.length; count++) {
            if ((betsRef.bet[self.list[count]] != betVal) || (betsRef.bet[self.list[count]] == 0)) {
                return (false);
            }
        }
        return (true);
    }
}

/**
* 
* Poker Hand Analysis library for CypherPoker.
*
* (C)opyright 2016
*
* This source code is protected by copyright and distributed under license.
* Please see the root LICENSE file for terms and conditions.
*
* Morden testnet address: 0x1887b0571d8e42632ca6509d31e3edc072408a90
*
*/
library PokerHandAnalyzer {
    
	using CryptoCards for *;
	
    /*
    Hand score:
    
    > 800000000 = straight/royal flush
    > 700000000 = four of a kind
    > 600000000 = full house
    > 500000000 = flush
    > 400000000 = straight
    > 300000000 = three of a kind
    > 200000000 = two pair
    > 100000000 = one pair
    > 0 = high card
    */   
	
	struct CardGroups {
		mapping (uint256 => CryptoCards.Card[15]) groups;
	}


	/*
	* Analyzes and scores a single 5-card permutation.
	*/
    function analyze(CryptoCards.Card[5] storage workCards, CryptoCards.Card[] storage sortedGroup, CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[][15] storage cardGroups) returns (uint256) {
		uint256 workingHandScore=0;
		bool acesHigh=false;  		
        sortWorkCards(workCards, cardGroups, acesHigh);
        workingHandScore=scoreStraights(sortedGroups, workCards, acesHigh);
        if (workingHandScore==0) {
           //may still be royal flush with ace high           
		   acesHigh=true;
		   sortWorkCards(workCards, cardGroups, acesHigh);
           workingHandScore=scoreStraights(sortedGroups, workCards, acesHigh);
        } else {
           //straight / straight flush 
           clearGroups(sortedGroup, sortedGroups, cardGroups);
           return (workingHandScore);
        }
        if (workingHandScore>0) {
           //royal flush
		   clearGroups(sortedGroup, sortedGroups, cardGroups);
           return (workingHandScore);
        } 
        clearGroups(sortedGroup, sortedGroups, cardGroups);
		acesHigh=false;
        groupWorkCards(true, sortedGroup, sortedGroups, workCards, cardGroups); //group by value
        if (sortedGroups.length > 4) {         
		    clearGroups(sortedGroup, sortedGroups, cardGroups);
			acesHigh=false;
            groupWorkCards(false, sortedGroup, sortedGroups, workCards, cardGroups); //group by suit
            workingHandScore=scoreGroups(false, sortedGroups, workCards, acesHigh);
        } else {
            workingHandScore=scoreGroups(true, sortedGroups, workCards, acesHigh);
        }
        if (workingHandScore==0) {            
			acesHigh=true;    
		    clearGroups(sortedGroup, sortedGroups, cardGroups);
            workingHandScore=addCardValues(0, sortedGroups, workCards, acesHigh);
        }
		clearGroups(sortedGroup, sortedGroups, cardGroups);
		return (workingHandScore);
    }
    
     /*
	* Sort work cards in preparation for group analysis and scoring.
	*/
    function groupWorkCards(bool byValue, CryptoCards.Card[] storage sortedGroup, CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[5] memory workCards,  CryptoCards.Card[][15] storage cardGroups) internal {
        for (uint count=0; count<5; count++) {
            if (byValue == false) {
                cardGroups[workCards[count].suit].push(CryptoCards.Card(workCards[count].index, workCards[count].suit, workCards[count].value));
            } 
            else {
                cardGroups[workCards[count].value].push(CryptoCards.Card(workCards[count].index, workCards[count].suit, workCards[count].value));
            }
        }
        uint8 maxValue = 15;
        if (byValue == false) {
            maxValue = 4;
        }
        uint pushedCards=0;
        for (count=0; count<maxValue; count++) {
           for (uint8 count2=0; count2<cardGroups[count].length; count2++) {
               sortedGroup.push(CryptoCards.Card(cardGroups[count][count2].index, cardGroups[count][count2].suit, cardGroups[count][count2].value));
               pushedCards++;
           }
           if (sortedGroup.length>0) {
             sortedGroups.push(sortedGroup);
			 sortedGroup.length=0;
           }
        }
    }
    
    
    function clearGroups(CryptoCards.Card[] storage sortedGroup, CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[][15] storage cardGroups) {
         for (uint count=0; count<sortedGroup.length; count++) {
             delete sortedGroup[count];
        }
        sortedGroup.length=0;
		for (count=0; count<cardGroups.length; count++) {
		    delete cardGroups[count];
        }
        for (count=0; count<sortedGroups.length; count++) {
             delete sortedGroups[count];
        }
        sortedGroups.length=0;
    }
    
    /*
	* Sort work cards in preparation for straight analysis and scoring.
	*/
	function sortWorkCards(CryptoCards.Card[5] memory workCards,  CryptoCards.Card[][15] storage cardGroups, bool acesHigh) internal {
        uint256 workValue;
		CryptoCards.Card[5] memory swapCards;
        for (uint8 value=1; value<15; value++) {
            for (uint8 count=0; count < 5; count++) {
                workValue=workCards[count].value;
                if (acesHigh && (workValue==1)) {
                    workValue=14;
                }
                if (workValue==value) {
                    swapCards[count]=workCards[count];
                }
            }
        }        
        for (count=0; count<swapCards.length; count++) {
			workCards[count]=swapCards[count];            
        }		
    }
        
   /*
	* Returns a straight score based on the current 5-card permutation, if a straigh exists.
	*/
	function scoreStraights(CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[5] memory workCards, bool acesHigh) internal returns (uint256) {
        uint256 returnScore;
        uint256 workValue;
        for (uint8 count=1; count<5; count++) {
            workValue = workCards[count].value;
            if (acesHigh && (workValue==1)) {
                workValue=14;
            }
            if ((workValue-workCards[count-1].value) != 1) {
                //not a straight, delta between sucessive values must be 1
                return (0);
            }
        }
        uint256 suitMatch=workCards[0].suit;
        returnScore=800000000; //straight flush
        for (count=1; count<5; count++) {
            if (workCards[count].suit != suitMatch) {
                returnScore=400000000; //straight (not all suits match)
                break;
            }
        }
        return(addCardValues(returnScore, sortedGroups, workCards, acesHigh));
    }    
    
    /*
	* Returns a group score based on the current 5-card permutation, if either suit or face value groups exist.
	*/
    function scoreGroups(bool valueGroups, CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[5] memory workCards, bool acesHigh) internal returns (uint256) {
        if (valueGroups) {
            //cards grouped by value
            if (checkGroupExists(4, sortedGroups)) {
                //four of a kind
                acesHigh=true;
                return (addCardValues(700000000, sortedGroups, workCards, acesHigh));
            } 
            else if (checkGroupExists(3, sortedGroups) && checkGroupExists(2, sortedGroups)) {
                //full house
                acesHigh=true;
                return (addCardValues(600000000, sortedGroups, workCards, acesHigh));
            }  
            else if (checkGroupExists(3, sortedGroups) && checkGroupExists(1, sortedGroups)) {
                //three of a kind
                acesHigh=true;
                return (addCardValues(300000000, sortedGroups, workCards, acesHigh));
            } 
            else if (checkGroupExists(2, sortedGroups)){
                uint8 groupCount=0;
                for (uint8 count=0; count<sortedGroups.length; count++) {
                    if (sortedGroups[count].length == 2) {
                        groupCount++;
                    }
                }
                acesHigh=true;
                if (groupCount > 1)  {
                    //two pair
                   return (addCardValues(200000000, sortedGroups, workCards, acesHigh));
                } else {
                    //one pair
                    return (addCardValues(100000000, sortedGroups, workCards, acesHigh));
                }
            }
        } 
        else {
            //cards grouped by suit
            if (sortedGroups[0].length==5) {
                //flush
                acesHigh=true;
                return (addCardValues(500000000, sortedGroups, workCards, acesHigh));
            }
        }
        return (0);
    }
    
	/*
	* Returns true if a group exists that has a specified number of members (cards) in it.
	*/
    function checkGroupExists(uint8 memberCount,  CryptoCards.Card[][] storage sortedGroups) returns (bool) {
        for (uint8 count=0; count<sortedGroups.length; count++) {
            if (sortedGroups[count].length == memberCount) {
                return (true);
            }
        }
        return (false);
    }
    
    /*
	* Adds individual card values to the hand score after group or straight scoring has been applied.
	*/
	function addCardValues(uint256 startingValue,  CryptoCards.Card[][] storage sortedGroups, CryptoCards.Card[5] memory workCards, bool acesHigh) internal returns (uint256) {
        uint256 groupLength=0;
        uint256 workValue;
        uint256 highestValue = 0;
        uint256 highestGroupValue = 0;
        uint256 longestGroup = 0;
        uint8 count=0;
        if (sortedGroups.length > 1) {
            for (count=0; count<sortedGroups.length; count++) {
                groupLength=getSortedGroupLength32(count, sortedGroups);
                for (uint8 count2=0; count2<sortedGroups[count].length; count2++) {
                    workValue=sortedGroups[count][count2].value;
                    if (acesHigh && (workValue==1)) {
                       workValue=14;
                    }
                    if ((sortedGroups[count].length>1) && (sortedGroups[count].length<5)) {
                        startingValue+=(workValue * (10**(groupLength+2))); //start at 100000
                        if ((longestGroup<groupLength) || ((longestGroup==groupLength) && (workValue > highestGroupValue))) {
                            //add weight to longest group or to work value when group lengths are equal (two pair)
                            highestGroupValue=workValue;
                            longestGroup=groupLength;
                        }
                    } 
                    else {
                        startingValue+=workValue;
                        if (workValue > highestValue) highestValue=workValue;
                    }
                }
            }
            startingValue+=highestValue**3;
            startingValue+=highestGroupValue*1000000;
        } 
        else {
            //bool isFlush=(workCards.length == sortedGroups[0].length);
            for (count=0; count<5; count++) {
                workValue=workCards[count].value;
                if (acesHigh && (workValue==1)) {
                   workValue=14;
                }
                startingValue+=workValue**(count+1); //cards are sorted so count+1 produces weight
                if (workValue > highestValue) {
                    highestValue=workValue;
                }
            }
            startingValue+=highestValue*1000000;
        }
        return (startingValue);
    }
    
    /*
    * Returns the group length of a specific sorted group as a uint32 (since .length property is natively uint256)
    */
    function getSortedGroupLength32(uint8 index,  CryptoCards.Card[][] storage sortedGroups)  returns (uint32) {
        uint32 returnVal;
         for (uint8 count=0; count<sortedGroups[index].length; count++) {
             returnVal++;
         }
         return (returnVal);
    }  
}