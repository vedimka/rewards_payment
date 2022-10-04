// SPDX-License-Identifier: UNLICENSED

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// Условия: 
// + 1. Вознаграждения перечисляются в виде ERC20 и ERC721 токенов. 
// + 2. Каждый этап выплаты вознаграждений ограничен количеством выплачиваемых токенов (общая сумма ERC20 токенов или количество ERC721 токенов)
// + 3. В каждом этапе может быть выплата до 5 разных ЕRC20 токенов (например, USDT и WBNB) и 1 ERC721
// + 4. Начисление вознаграждения привязывается к конкретному адресу
// + 5. Вознаграждение выплачивается транзакцией пользователя на контракт (комиссию платит пользователь)
// + 6. Награждение выплачивается через трансфер токенов c баланса контракта на адрес получателя
// + 7. Владелец контракта может в любой момент остановить выплату вознаграждений
// + 8. Владелец контракта может инициировать новые этапы вознаграждений с отдельными лимитами по количеству выплачиваемых токенов
// + 9. Вознаграждение может получить только тот адрес для которого был сгенерирован код

// WorkFlow:
// + Входящие данные: список кошельков и сумма начисленной награды на каждый кошелек.

// + 1. Владелец смарт контракта инициирует новый этап вознаграждений с указанием общей суммы выплаты по токенам

// +/- 2. На стороне сервера при запросе на каждый адрес генерируется подпись и передается пользователю по открытому каналу

// +/- 3. Пользователь, получив подпись, может провести транзакцию в смарт контракт и получить начисленное ему вознаграждение

// Необходимо: 
// + 1. Разработать смарт-контракт выплаты вознаграждений
// 2. Разработать скрипт генерации кодов для пользователей на nodeJS (на вход получаем адрес кошелька пользователя, адрес токена и сумму (или количество для ЕRC721) на выходе подпись для транзакции)
// Бонусом:
// + 1. Разработать скрипт деплоя смарт-контракта в тестовую сеть
// +/- 2. Разработать тесты основного функционала смарт-контракта в связке со скриптом генерации кодов для выплаты
//  Мы делаем подпись на сервере, и позволяем пользователю самому сделать себе выплату с контракта, и следовательно пользователь сам заплатит за это действие.

// Нет необходимости хранить данные кто и сколько в каком раунде получает так как теряется смысл проверки подписи.
// В таком случае мы можем просто передать в контракт список получателей, токены и суммы какие хотим раздать.
// Идея контракта - обработать очень большое число получателей - которое мы физически не можем записать на контракт так как это очень дорого по стоимости транзакции.
// На контракте храним только список токенов которые раздаем в раунде и общую сумму по каждому токену , а так же отслеживаем сколько в каждом раунде уже сняли.

// При выплате вознаграждения, на контракт должны передать номер раунда, токены, суммы и подпись, сформированную всеми этим данными. 
// На контракте мы должны проверить что подпись сгенерирована именно с этих данных и подписана нашим сервером.
// В текущей реализации теряется смысл подписи и ее проверки на контракте так как можно с одной подписью получать вознаграждение каждый раз когда получатель появляется в мапинге recipientsRewards

contract Rewarder is Ownable{

    using ECDSA for bytes32;

    using SafeERC20 for IERC20;

    IERC721 NFT;

    enum PaymentStatuses {Active, Paused}

    PaymentStatuses paymentStatus;

    address signer;

    constructor(address nftAddress){
        NFT = IERC721(nftAddress);
        paymentStatus = PaymentStatuses.Active;
        signer = owner();
    }
    
    struct RewardReceipt{
        address recipient;
        Token[] tokens;
        uint [] nftIds;
        //Описать какие данные мы подписываем
        //отправителя, адрес токена, сумму, токенИД для НФТ
    }
    struct Reward {
        uint roundId;
        address recipient;
        Token[] tokens;
        uint [] nftIds;
    }

    // struct CreateRewardRoundInterface {
    //     address recipient;
    //     Token[] tokens;
    //     uint [] nftIds;
    // }

    struct Token {
        address tokenAddress;
        uint amount;
    }

    // mapping(uint => mapping(address => bool)) public executed;
    mapping(bytes32 => bool) public executed;
    mapping(uint => Token[]) public amountTokensRewardRound;
    mapping(uint => uint) public amountNftReward;   
    uint rewardRoundId;

    function createRewards(
        address [] memory _rewardReceipts,
        bytes32 [] memory _msgHash,
        uint [] calldata _UUID,
        Token [] calldata _tokens, 
        uint _amountNft
        ) public{
        Token[] storage tokens =  amountTokensRewardRound[rewardRoundId];
        for(uint i = 0; i <_tokens.length; i++){
            tokens.push(Token(_tokens[i].tokenAddress, _tokens[i].amount));
        }
        rewardRoundId++;
    }
    
    function getRewards(
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bytes32 _UUID,//uuid to proceed identical receipts to always generate different hashes
        RewardReceipt[] calldata _rewardReceipts
    ) public view {
        // address sender = 
        bytes32 msgHash = keccak256(abi.encode(msg.sender, _UUID, _rewardReceipts)); //воссоздаем сообщение которое подписывали на сервере
        // bytes32 msgHash = keccak256(abi.encode(recipient, _UUID, _rewardReceipts)); 
        require(!executed[msgHash], "Rewarder: Has been executed!"); //проверяем что по этой подписи не выплачивали еще
        // executed[msgHash] = true; 
        // ECDSA.recover(msgHash.toEthSignedMessageHash(), _signature);
        address _signer = verifyHash(msgHash, _v, _r, _s);
        require(_signer == signer, "Rewarder: signer not recovered from signed tx!"); //msgHash.toEthSignedMessageHash(),
        // require(msgHash.toEthSignedMessageHash().recover( _signature ) == signer, "Rewarder:: signer not recovered from signed tx!"); //msgHash.toEthSignedMessageHash(),

    }

    function msgHash(
        bytes32 _signature,
        bytes32 _UUID,//uuid to proceed identical receipts to always generate different hashes
        RewardReceipt[] calldata _rewardReceipts
    ) public view returns(bytes32){
        bytes32 msgHash = keccak256(abi.encode(msg.sender, _UUID, _rewardReceipts)); 
    }

    function test(address recipient, bytes32 _UUID, RewardReceipt[] calldata _rewardReceipts ) public view returns(bytes32){
        bytes32 msgHash = keccak256(abi.encode(msg.sender, _UUID, _rewardReceipts)); 
        return msgHash;
    }

    function verifyHash(bytes32 hash, uint8 v, bytes32 r, bytes32 s) public pure
        returns (address signer) {

        bytes32 messageDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));//(...));

        return ecrecover(messageDigest, v, r, s);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4){
        return IERC721Receiver.onERC721Received.selector;
    }

}
//Проверяем что данные соответствуют подписи и подписывал сервер