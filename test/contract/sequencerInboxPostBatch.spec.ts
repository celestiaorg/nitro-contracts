/*
 * Copyright 2019-2020, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* eslint-env node, mocha */

import { ethers } from 'hardhat'
import {
  Bridge__factory,
  GasRefunder,
  RollupMock__factory,
  Inbox__factory,
  MessageTester,
  SequencerInbox,
  SequencerInbox__factory,
  TransparentUpgradeableProxy__factory,
  GasRefunderOpt,
  GasRefunderOpt__factory,
} from '../../build/types'
import { data } from './batchData.json'
import { initializeAccounts } from './utils'

describe('SequencerInboxPostBatch', async () => {

  const setupSequencerInbox = async () => {
    const accounts = await initializeAccounts()
    const admin = accounts[0]
    const adminAddr = await admin.getAddress()
    const user = accounts[1]
    const rollupOwner = accounts[2]
    const batchPoster = accounts[3]

    const rollupMockFac = (await ethers.getContractFactory(
      'RollupMock'
    )) as RollupMock__factory
    const rollup = await rollupMockFac.deploy(await rollupOwner.getAddress())
    const inboxFac = (await ethers.getContractFactory(
      'Inbox'
    )) as Inbox__factory
    const inboxTemplate = await inboxFac.deploy(117964)
    const bridgeFac = (await ethers.getContractFactory(
      'Bridge'
    )) as Bridge__factory
    const bridgeTemplate = await bridgeFac.deploy()
    const transparentUpgradeableProxyFac = (await ethers.getContractFactory(
      'TransparentUpgradeableProxy'
    )) as TransparentUpgradeableProxy__factory

    const bridgeProxy = await transparentUpgradeableProxyFac.deploy(
      bridgeTemplate.address,
      adminAddr,
      '0x'
    )

    const sequencerInboxFac = (await ethers.getContractFactory(
      'SequencerInbox'
    )) as SequencerInbox__factory
    const seqInboxTemplate = await sequencerInboxFac.deploy(
      117964
    )
    const sequencerInboxProxy = await transparentUpgradeableProxyFac.deploy(
      seqInboxTemplate.address,
      adminAddr,
      '0x'
    )
    const inboxProxy = await transparentUpgradeableProxyFac.deploy(
      inboxTemplate.address,
      adminAddr,
      '0x'
    )
    const bridge = await bridgeFac.attach(bridgeProxy.address).connect(user)
    const bridgeAdmin = await bridgeFac
      .attach(bridgeProxy.address)
      .connect(rollupOwner)
    await bridge.initialize(rollup.address)
    const sequencerInbox = await sequencerInboxFac
      .attach(sequencerInboxProxy.address)
      .connect(user)
    await sequencerInbox.initialize(bridge.address,       {
      delayBlocks: 7200,
      delaySeconds: 86400,
      futureBlocks: 10,
      futureSeconds: 3000,
    },)

    const inbox = await inboxFac.attach(inboxProxy.address).connect(user)

    await inbox.initialize(bridgeProxy.address, sequencerInbox.address)

    await bridgeAdmin.setDelayedInbox(inbox.address, true)
    await bridgeAdmin.setSequencerInbox(sequencerInbox.address)

    await (
      await sequencerInbox
        .connect(rollupOwner)
        .setIsBatchPoster(await batchPoster.getAddress(), true)
    ).wait()

    return {
      bridge,
      sequencerInbox,
      batchPoster,
    }
  }

  const setupGasRefunder = async(allowedContracts: string[], allowedRefundees: string[]) => {
    const accounts = await initializeAccounts();
    const gasRefunder = await (
      await ethers.getContractFactory('GasRefunder')
    ).deploy() as GasRefunder;
    await gasRefunder.allowRefundees(allowedRefundees);
    await gasRefunder.allowContracts(allowedContracts);
    accounts[0].sendTransaction({
      to: gasRefunder.address,
      value: ethers.utils.parseEther('10.0'),
    });
    return gasRefunder;
  }

  const setupGasRefunderOptimized = async(allowedContract: string, allowedRefundee: string) => {
    const accounts = await initializeAccounts();
    const gasOptFac = (await ethers.getContractFactory(
      'GasRefunderOpt'
    )) as GasRefunderOpt__factory

    const gasRefunder = await gasOptFac.deploy(
      allowedContract,
      allowedRefundee,
      ethers.constants.Zero,
      76400,
      16,
      ethers.utils.parseUnits('2', 'gwei'),
      ethers.utils.parseUnits('120', 'gwei'),
      2e6, // 2 million gas
    ) as GasRefunderOpt;
    accounts[0].sendTransaction({
      to: gasRefunder.address,
      value: ethers.utils.parseEther('10.0'),
    });
    return gasRefunder;
  }

  it('can post batch', async () => {
    const { bridge, sequencerInbox, batchPoster } =
      await setupSequencerInbox()
    const gasRefunder = await setupGasRefunder([sequencerInbox.address], [await batchPoster.getAddress()]);
    const gasRefunderOpt = await setupGasRefunderOptimized(sequencerInbox.address, await batchPoster.getAddress());
    const seqReportedMessageSubCount = await bridge.sequencerMessageCount()
    await (
      await sequencerInbox
        .connect(batchPoster)
        ['addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'](
          0,
          data,
          0,
          ethers.constants.AddressZero,
          seqReportedMessageSubCount,
          seqReportedMessageSubCount.add(10),
          { gasLimit: 10000000 }
        )
    ).wait()
    const res1 = await (
      await sequencerInbox
        .connect(batchPoster)
        ['addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'](
          1,
          data,
          0,
          ethers.constants.AddressZero,
          seqReportedMessageSubCount.add(10),
          seqReportedMessageSubCount.add(20),
          { gasLimit: 10000000 }
        )
    ).wait()
    const res2 = await (
      await sequencerInbox
        .connect(batchPoster)
        ['addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'](
          2,
          data,
          0,
          gasRefunder.address,
          seqReportedMessageSubCount.add(20),
          seqReportedMessageSubCount.add(30),
          { gasLimit: 10000000 }
        )
    ).wait()
    const res3 = await (
      await sequencerInbox
        .connect(batchPoster)
        ['addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'](
          3,
          data,
          0,
          gasRefunderOpt.address,
          seqReportedMessageSubCount.add(30),
          seqReportedMessageSubCount.add(40),
          { gasLimit: 10000000 }
        )
    ).wait()

    console.log('Gas used for batch posting: ', res1.gasUsed.toNumber())
    console.log('Gas used for batch posting with refund: ', res2.gasUsed.toNumber())
    console.log('Gas used for batch posting with refund (opt): ', res3.gasUsed.toNumber())
  })

})
