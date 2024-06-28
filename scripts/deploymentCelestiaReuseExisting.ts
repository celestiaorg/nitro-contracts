import { ethers } from 'hardhat'
import { ContractFactory, Contract, Overrides } from 'ethers'
import '@nomiclabs/hardhat-ethers'
import { deployContract } from './deploymentUtils'
import { ArbSys__factory } from '../build/types'
import { ARB_SYS_ADDRESS } from '@arbitrum/sdk/dist/lib/dataEntities/constants'
import { Toolkit4844 } from '../test/contract/toolkit4844'

async function _isRunningOnArbitrum(signer: any): Promise<Boolean> {
  const arbSys = ArbSys__factory.connect(ARB_SYS_ADDRESS, signer)
  try {
    await arbSys.arbOSVersion()
    return true
  } catch (error) {
    return false
  }
}

async function main() {
  const [signer] = await ethers.getSigners()

  try {

    const rollupCreator = await deployContract('RollupCreator', signer, [], true)
    // deploy Sequencer Inbox,
    const isOnArb = await _isRunningOnArbitrum(signer)
    const reader4844 = isOnArb
      ? ethers.constants.AddressZero
      : (await Toolkit4844.deployReader4844(signer)).address

    // NOTE: maxDataSize is set for an L3, if deploying an L2 use "const maxDataSize = 117964"
    const maxDataSize = 104857
    const ethSequencerInbox = await deployContract('SequencerInbox', signer, [
      maxDataSize,
      reader4844,
      false,
    ], true)

    const erc20SequencerInbox = await deployContract('SequencerInbox', signer, [
      maxDataSize,
      reader4844,
      true,
    ], true)

    const bridgeCreator = await deployContract('BridgeCreator', signer, [
      [
        "0x38f918D0E9F1b721EDaA41302E399fa1B79333a9",
        ethSequencerInbox.address,
        "0xaAe29B0366299461418F5324a79Afc425BE5ae21",
        "0xB5a0Bd4E13F02A0be8AF0b6912c7F40377b4faa7",
        "0x6fC72dC06891Fd862Fb25C53831E1b126B2516Ca",
      ],
      [
        "0x20C02F9425a9Fb802cB549f19Ea65eb8D5f53B3B",
        erc20SequencerInbox.address,
        "0x63F5A0AD3E82Eec97D80Fc657b06E84E35bcD662",
        "0x27406ac11Bd8DcA4391AaBDa21B38cCc4b5d6e55",
        "0xFc06B350Dafc5f8F43e24e87C9E9ce0513e337aC",
      ],
    ], true)

    // deploy OSP

    const prover0 = await deployContract('OneStepProver0', signer, [], true)
    const proverMem = await deployContract('OneStepProverMemory', signer, [], true)
    const proverMath = await deployContract('OneStepProverMath', signer, [], true)
    const proverHostIo = await deployContract('OneStepProverHostIo', signer, [], true)
    const osp: Contract = await deployContract('OneStepProofEntry', signer, [
      prover0.address,
      proverMem.address,
      proverMath.address,
      proverHostIo.address,
    ], true)

    // Call setTemplates with the deployed contract addresses
    console.log('Waiting for the Template to be set on the Rollup Creator')
    await rollupCreator.setTemplates(
      bridgeCreator.address,
      osp.address,
      "0x421516057fC1152481bD440E844A485589E7BC93",
      "0x0903Eb747Ff36b8CA3F2E4CBBCe0a2A736d1FA36",
      "0xFA4481E69B5f447f6aED6D4C3778d419302165E1",
      "0x52aaDE68555c04988e0f53c4e52797Ed2D30aD70",
      "0xb33Dca7b17c72CFC311D68C543cd4178E0d7ce55",
      "0x75500812ADC9E51b721BEa31Df322EEc66967DDF",
      "0x80bD13f81bB218Ed8f5128b196C43bd6444ebdEf"
    )
    console.log('Template is set on the Rollup Creator')
  } catch (error) {
    console.error(
      'Deployment failed:',
      error instanceof Error ? error.message : error
    )
  }
}

main()
  .then(() => process.exit(0))
  .catch((error: Error) => {
    console.error(error)
    process.exit(1)
  })
