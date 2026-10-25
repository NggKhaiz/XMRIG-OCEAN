/* XMRig
 * Copyright (c) 2018-2022 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2022 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef XMRIG_DONATE_H
#define XMRIG_DONATE_H


/*
 * Dev donation.
 *
 * THIS BUILD IS PERMANENTLY FEE-FREE (0%): both the default and the minimum
 * donation level are zero, the donation strategy was removed from the binary
 * and `Network` never instantiates a second stratum session.
 *
 * Consequences, all of them intentional:
 *   - 100% of the hashing time is spent on the pools configured by the user;
 *   - no runtime context switch between pools, so no RandomX dataset rebuild,
 *     no VM teardown and no lost nonce scope;
 *   - `--donate-level` / `donate-level` are still accepted for compatibility
 *     with existing scripts and configs, but they are ignored.
 *
 * If you want to support the upstream XMRig developers, do it as a voluntary
 * one-off donation through the address published in the upstream README.
 * There is intentionally no wallet address compiled into this tree.
 */
constexpr const int kDefaultDonateLevel = 0;
constexpr const int kMinimumDonateLevel = 0;


#endif // XMRIG_DONATE_H
