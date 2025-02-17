FROM swift:5.3.2-bionic

RUN apt-get update
RUN apt-get install -y apt-utils

# Install Basics
RUN apt-get install -y git curl

# Install Python
RUN rm -rf /usr/lib/python2.7/site-packages
RUN apt-get install -y python python-dev python-pip
RUN apt-get install -y python3 python3-dev python3-pip

# Install jinja
RUN python3 -m pip install --upgrade pip
RUN python3 -m pip install jinja2

# Install pyverilog
RUN python3 -m pip install https://github.com/PyHDI/Pyverilog/archive/refs/tags/1.3.0.zip

# Install Yosys
RUN apt-get install -y yosys

# Install IcarusVerilog 10.2+
RUN mkdir -p /share/iverilog
WORKDIR /share/iverilog
RUN curl -sL https://github.com/FPGAwars/toolchain-iverilog/releases/download/v1.2.1/toolchain-iverilog-linux_x86_64-1.2.1.tar.gz | tar -xzf -

# Install Atalanta
RUN curl -sL https://github.com/hsluoyz/Atalanta/archive/master.tar.gz | tar -xzf -
WORKDIR Atalanta-master
RUN make
RUN cp atalanta /usr/bin

# Install PODEM 
RUN apt-get install -y flex bison libreadline-dev libncurses5-dev libncursesw5-dev
RUN curl -sL http://tiger.ee.nctu.edu.tw/course/Testing2018/assignments/hw0/podem.tgz  | tar -xzf -
WORKDIR podem
RUN make
RUN cp atpg /usr/bin

# Install Fault
ENV PYVERILOG_IVERILOG="/share/iverilog/bin/iverilog"
ENV FAULT_IVERILOG="/share/iverilog/bin/iverilog"
ENV FAULT_VVP="/share/iverilog/bin/vvp"
ENV FAULT_YOSYS="yosys"
ENV FAULT_IVL_BASE="/share/iverilog/lib/ivl"

# For Pyverilog:
RUN ln -s $FAULT_IVL_BASE "/usr/local/lib/ivl" 

WORKDIR /share
COPY . /share/Fault
WORKDIR /share/Fault
RUN INSTALL_DIR=/usr/bin swift install.swift
WORKDIR /