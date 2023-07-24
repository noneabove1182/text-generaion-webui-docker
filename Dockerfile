# cuda devel image for base, best build compatibility
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 as builder

# Using conda to transfer python env from builder to runtime later
COPY --from=continuumio/miniconda3:4.12.0 /opt/conda /opt/conda
ENV PATH=/opt/conda/bin:$PATH

# Update base image
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y git build-essential \
    ocl-icd-opencl-dev opencl-headers clinfo \
    && mkdir -p /etc/OpenCL/vendors && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# Create new conda environment
RUN conda create -y -n textgen python=3.10.9
SHELL ["conda", "run", "-n", "textgen", "/bin/bash", "-c"]

# Installing torch and ninja
RUN pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

RUN pip3 install ninja

# Pulling latest text-generation-webui branch
RUN git clone https://github.com/oobabooga/text-generation-webui.git --branch v1.3.1 \
    && cd text-generation-webui && pip3 install -r requirements.txt

# Install all the extension requirements
RUN bash -c 'for i in text-generation-webui/extensions/*/requirements.txt ; do pip3 install -r $i ; done'

# Prepare cache for faster first time runs
RUN python3 text-generation-webui/extensions/openai/cache_embedding_model.py

# Installing latest llamacpp python bindings
RUN pip3 uninstall -y llama-cpp-python \
    && CMAKE_ARGS="-DLLAMA_CUBLAS=on" FORCE_CMAKE=1 pip3 install llama-cpp-python==0.1.74 --no-cache-dir

# Making latest bitsandbytes with cuda support
RUN pip3 uninstall -y bitsandbytes \
    && git clone https://github.com/TimDettmers/bitsandbytes.git --branch 0.41.0 \
    && cd bitsandbytes && CUDA_VERSION=118 make cuda11x \
    && python3 setup.py install

# Make sure exllama is removed and include latest exllama with gqa support until next text-gen update
RUN pip3 uninstall -y exllama
RUN mkdir -p text-generation-webui/repositories/ && cd text-generation-webui/repositories/ \
    && git clone https://github.com/turboderp/exllama && cd exllama && git checkout e8a544f95b3fd64dfa5549eeeafb85b1ac71a793

RUN conda clean -afy

# Using runtime for smaller final image
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04

# Copy conda and cuda files over
COPY --from=builder /opt/conda /opt/conda
COPY --from=builder /usr/local/cuda-11.8/targets/x86_64-linux/include /usr/local/cuda-11.8/targets/x86_64-linux/include 
COPY --from=builder /etc/OpenCL/vendors/nvidia.icd /etc/OpenCL/vendors/nvidia.icd

ENV PATH=/opt/conda/bin:$PATH

# Copy git repo from builder
COPY --from=builder /text-generation-webui /text-generation-webui

# Setting frontend to noninteractive to avoid getting locked on keyboard input
ENV DEBIAN_FRONTEND=noninteractive

# Installing all the packages we need and updating cuda-keyring
RUN apt-get -y update && apt-get -y install wget && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb \
    && dpkg -i cuda-keyring_1.0-1_all.deb && apt-get update && apt-get upgrade -y \
    && apt-get -y install python3 build-essential \
    && mkdir -p /etc/OpenCL/vendors \
    && apt-get -y install cuda-11.8 && apt-get -y install cuda-11.8 \
    && systemctl enable nvidia-persistenced \
    && cp /lib/udev/rules.d/40-vm-hotadd.rules /etc/udev/rules.d \
    && sed -i '/SUBSYSTEM=="memory", ACTION=="add"/d' /etc/udev/rules.d/40-vm-hotadd.rules \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set the working directory
WORKDIR /text-generation-webui

EXPOSE 7860
EXPOSE 5000

# start.sh sets up the various available directories like models and characters
# Also provides a conda env activated entrypoint
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Define the entrypoint
ENTRYPOINT ["/start.sh"]
