# Latency Ninja

Latency Ninja is a wrapper tool for tc/netem that allows you to simulate network conditions like latency, jitter, corruption, duplication, reordering, and packet loss on a given interface to a destination IP address.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Features](#features)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

1. Make sure you have `tc` and `netem` installed on your system.
3. Root or superuser privileges are required to run the script.

## Installation

1. Clone this repository:

    git clone [URL_OF_THIS_REPOSITORY]
    
2. Navigate to the directory

	cd latencyninja

3. Give executable permissions to the script
    chmod +x latency_ninja.sh

 ## Usage

    ./latency_ninja.sh [OPTIONS]
        
    Options:
    -i: The network interface (e.g., eth0). This is mandatory.
    -d: Destination IP address. This is mandatory if latency or jitter are applied.
    -l: Latency in milliseconds.
    -j: Jitter in milliseconds.
    -c: Corruption in percentage.
    -u: Duplication in percentage.
    -r: Reorder in percentage.
    -p: Packet loss in percentage.
    -R: Rollback/Revert the applied network conditions.

## Example
Example: To simulate 100ms latency, 10ms jitter, and 5% packet loss on the eth0 interface for traffic going to 192.168.1.10, run:

    ./latency_ninja.sh -i eth0 -d 192.168.1.10 -l 100 -j 10 -p 5

## Features

 - Latency Simulation: Simulates the amount of delay in the network.
 - Jitter: Adds variability to the latency. 
 - Corruption: Corrupts a given percentage of packets. 
 - Duplication: Duplicates a certain percentage of packets. Reorder: Reorders the sequence of packets. 
 - Packet Loss: Drops a percentage of packets. Rollback: Provides an easy way to revert the applied network conditions. 

## Troubleshooting
 - Permission Denied: Make sure you're running the script with superuser privileges.
 - Interface Error: Ensure that the provided network interface exists and is up.
 - Missing Parameters: Always ensure that mandatory parameters like -i and -d are provided, especially when using -l or -j.

## Contributing
We welcome contributions! If you'd like to contribute, please create a pull request with your changes.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.


