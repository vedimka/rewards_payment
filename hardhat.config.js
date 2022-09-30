require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
        {
          version:"0.4.17"
        },
        {
          version:"0.8.9",
          settings:{}
        }
      ],
    overrides: {
      "contracts/TetherToken.sol": {
        version: "0.4.17",
        settings: { }
      }
    }
  }
};