/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include <math.h>
#include <torch/extension.h>
#include <cstdio>
#include <sstream>
#include <iostream>
#include <tuple>
#include <stdio.h>
#include <cuda_runtime_api.h>
#include <memory>
#include "cuda_rasterizer/config.h"
#include "cuda_rasterizer/rasterizer.h"
#include "cuda_rasterizer/rasterizer_impl.h"
#include <fstream>
#include <string>
#include <functional>

std::function<char*(size_t N)> resizeFunctional(torch::Tensor& t) {
    auto lambda = [&t](size_t N) {
        t.resize_({(long long)N});
		return reinterpret_cast<char*>(t.contiguous().data_ptr());
    };
    return lambda;
}

std::tuple<int, int, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
RasterizeGaussiansCUDA(
	const torch::Tensor& background,
	const torch::Tensor& means3D,
    const torch::Tensor& colors,
	const torch::Tensor& flows,
    const torch::Tensor& opacity,
	const torch::Tensor& ts,
	const torch::Tensor& scales,
	const torch::Tensor& scales_t,
	const torch::Tensor& rotations,
	const torch::Tensor& rotations_r,
	const torch::Tensor& means3D_static,
	const torch::Tensor& sh_static,
	const torch::Tensor& opacities_static,
	const torch::Tensor& scales_static,
	const torch::Tensor& rotations_static,
	const float scale_modifier,
	const torch::Tensor& cov3D_precomp,
	const torch::Tensor& viewmatrix,
	const torch::Tensor& projmatrix,
	const float tan_fovx,
	const float tan_fovy,
    const int image_height,
    const int image_width,
	const torch::Tensor& sh,
	const int degree,
	const int degree_t, 
	const torch::Tensor& campos,
	const float timestamp,
	const float time_duration,
	const bool rot_4d,
	const int gaussian_dim,
	const bool force_sh_3d,
	const bool prefiltered,
	const float opa_threshold,
	const bool debug)
{
  if (means3D.ndimension() != 2 || means3D.size(1) != 3) {
    AT_ERROR("means3D must have dimensions (num_points, 3)");
  }
  
  const int P = means3D.size(0);
  const int P_static = means3D_static.size(0);
  const int P_total = P + P_static;
  const int H = image_height;
  const int W = image_width;

  auto int_opts = means3D.options().dtype(torch::kInt32);
  auto float_opts = means3D.options().dtype(torch::kFloat32);

  torch::Tensor out_color = torch::full({NUM_CHANNELS, H, W}, 0.0, float_opts);
  torch::Tensor out_flow = torch::full({2, H, W}, 0.0, float_opts);
  torch::Tensor out_depth = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor out_invdepth = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor out_4D = torch::full({NUM_CHANNELS, H, W}, 0.0, float_opts);
  torch::Tensor out_3D = torch::full({NUM_CHANNELS, H, W}, 0.0, float_opts);
  torch::Tensor out_T = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor radii = torch::full({P}, 0, means3D.options().dtype(torch::kInt32));
  torch::Tensor radii_static = torch::full({P_static}, 0, means3D.options().dtype(torch::kInt32));
  torch::Tensor out_means3D = means3D.clone();

  
  torch::Device device(torch::kCUDA);
  torch::TensorOptions options(torch::kByte);
  torch::Tensor geomBuffer = torch::empty({0}, options.device(device));
  torch::Tensor binningBuffer = torch::empty({0}, options.device(device));
  torch::Tensor imgBuffer = torch::empty({0}, options.device(device));
  torch::Tensor sampleBuffer = torch::empty({0}, options.device(device));
  std::function<char*(size_t)> geomFunc = resizeFunctional(geomBuffer);
  std::function<char*(size_t)> binningFunc = resizeFunctional(binningBuffer);
  std::function<char*(size_t)> imgFunc = resizeFunctional(imgBuffer);
  std::function<char*(size_t)> sampleFunc = resizeFunctional(sampleBuffer);
  
  int rendered = 0;
  int num_buckets = 0;
  if(P != 0)
  {
	  int M = 0;
	  if(sh.size(0) != 0)
	  {
		M = sh.size(1);
      }

	  auto tup = CudaRasterizer::Rasterizer::forward(
	    geomFunc,
		binningFunc,
		imgFunc,
		sampleFunc,
	    P, P_static, P_total, degree, degree_t, M,
		background.contiguous().data_ptr<float>(),
		W, H,
		means3D.contiguous().data_ptr<float>(),
		out_means3D.contiguous().data_ptr<float>(),
		sh.contiguous().data_ptr<float>(),
		colors.contiguous().data_ptr<float>(), 
		flows.contiguous().data_ptr<float>(),
		opacity.contiguous().data_ptr<float>(), 
		ts.contiguous().data_ptr<float>(), 
		scales.contiguous().data_ptr<float>(),
		scales_t.contiguous().data_ptr<float>(), 
		scale_modifier,
		rotations.contiguous().data_ptr<float>(),
		rotations_r.contiguous().data_ptr<float>(),
		cov3D_precomp.contiguous().data_ptr<float>(), 
		viewmatrix.contiguous().data_ptr<float>(), 
		projmatrix.contiguous().data_ptr<float>(),
		campos.contiguous().data_ptr<float>(),
		timestamp,
		time_duration,
		rot_4d,
		gaussian_dim,
		force_sh_3d,
		tan_fovx,
		tan_fovy,
		prefiltered,
		out_color.contiguous().data_ptr<float>(),
		out_invdepth.contiguous().data_ptr<float>(),
		out_flow.contiguous().data_ptr<float>(), 
		out_depth.contiguous().data_ptr<float>(),
		out_4D.contiguous().data_ptr<float>(),
		out_3D.contiguous().data_ptr<float>(),
		out_T.contiguous().data_ptr<float>(),
		opa_threshold,
		means3D_static.contiguous().data_ptr<float>(),
		opacities_static.contiguous().data_ptr<float>(),
		scales_static.contiguous().data_ptr<float>(),
		rotations_static.contiguous().data_ptr<float>(),
		sh_static.contiguous().data_ptr<float>(),
		radii.contiguous().data_ptr<int>(),
		radii_static.contiguous().data_ptr<int>(),
		debug);

		rendered = std::get<0>(tup);
		num_buckets = std::get<1>(tup);
  }
  char* geo_ptr = reinterpret_cast<char*>(geomBuffer.contiguous().data_ptr());
  CudaRasterizer::GeometryState geoState = CudaRasterizer::GeometryState::fromChunk(geo_ptr, P, P_static,P_total);

  torch::Tensor covs3D_com = torch::from_blob(geoState.cov3D, {P, 6}, float_opts);
  return std::make_tuple(rendered, num_buckets, out_color, out_flow, out_depth, out_T, radii, geomBuffer, binningBuffer, imgBuffer, sampleBuffer, covs3D_com, out_means3D, radii_static, out_4D, out_3D, out_invdepth);
}

std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
 RasterizeGaussiansBackwardCUDA(
 	const torch::Tensor& background,
	const torch::Tensor& means3D,
	const torch::Tensor& out_means3D,
	const torch::Tensor& radii,
    const torch::Tensor& colors,
	const torch::Tensor& flows_2d,
    const torch::Tensor& opacities,
    const torch::Tensor& ts,
	const torch::Tensor& scales,
	const torch::Tensor& scales_t,
	const torch::Tensor& rotations,
	const torch::Tensor& rotations_r,
	const torch::Tensor& means3D_static,
	const torch::Tensor& radii_static,
	const torch::Tensor& sh_static,
	const torch::Tensor& opacities_static,
	const torch::Tensor& scales_static,
	const torch::Tensor& rotations_static,
	const float scale_modifier,
	const torch::Tensor& cov3D_precomp,
	const torch::Tensor& viewmatrix,
    const torch::Tensor& projmatrix,
	const float tan_fovx,
	const float tan_fovy,
    const torch::Tensor& dL_dout_color,
	const torch::Tensor& dL_dout_depth,
	const torch::Tensor& dL_dout_mask,
	const torch::Tensor& dL_dout_flow,
	const torch::Tensor& sh,
	const torch::Tensor& dL_dout_invdepth,
	const int degree,
	const int degree_t,
	const torch::Tensor& campos,
	const float timestamp,
	const float time_duration,
	const bool rot_4d,
	const int gaussian_dim,
	const bool force_sh_3d,
	const torch::Tensor& geomBuffer,
	const int R,
	const torch::Tensor& binningBuffer,
	const torch::Tensor& imageBuffer,
	const int B,
	const torch::Tensor& sampleBuffer,
	const bool debug) 
{
  const int P = means3D.size(0);
  const int P_static = means3D_static.size(0);
  const int H = dL_dout_color.size(1);
  const int W = dL_dout_color.size(2);
  
  int M = 0;
  if(sh.size(0) != 0)
  {	
	M = sh.size(1);
  }

  torch::Tensor dL_dmeans3D = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dmeans2D = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dcolors = torch::zeros({P, NUM_CHANNELS}, means3D.options());
  torch::Tensor dL_dflows = torch::zeros({P, 2}, means3D.options());
  torch::Tensor dL_dconic = torch::zeros({P, 2, 2}, means3D.options());
  torch::Tensor dL_dopacity = torch::zeros({P, 1}, means3D.options());
  torch::Tensor dL_dts = torch::zeros({P, 1}, means3D.options());
  torch::Tensor dL_dcov3D = torch::zeros({P, 6}, means3D.options());
  torch::Tensor dL_dsh = torch::zeros({P, M, 3}, means3D.options());
  torch::Tensor dL_dscales = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dscales_t = torch::zeros({P, 1}, means3D.options());
  torch::Tensor dL_drotations = torch::zeros({P, 4}, means3D.options());
  torch::Tensor dL_drotations_r = torch::zeros({P, 4}, means3D.options());

  torch::Tensor dL_dmeans3D_static, dL_dmeans2D_static, dL_dcolors_static, 
              dL_dconic_static, dL_dopacity_static, dL_dcov3D_static, 
              dL_dsh_static, dL_dscales_static, dL_drotations_static;

  dL_dmeans3D_static = torch::zeros({P_static, 3}, means3D.options());
  dL_dcolors_static = torch::zeros({P_static, NUM_CHANNELS}, means3D.options());
  dL_dconic_static = torch::zeros({P_static, 2, 2}, means3D.options());
  dL_dopacity_static = torch::zeros({P_static, 1}, means3D.options());
  dL_dcov3D_static = torch::zeros({P_static, 6}, means3D.options());
  dL_dsh_static = torch::zeros({P_static, M, 3}, means3D.options());
  dL_dscales_static = torch::zeros({P_static, 3}, means3D.options());
  dL_drotations_static = torch::zeros({P_static, 4}, means3D.options());

  if (P_static == 0){
	dL_dmeans2D_static = torch::zeros({P_static}, means3D.options());
	
  }
  else if (P_static != 0){
	dL_dmeans2D_static = torch::zeros({P_static, 3}, means3D.options());
  }

  if(P != 0)
  {  
	  CudaRasterizer::Rasterizer::backward(P, P_static, degree, degree_t, M, R, B,
	  background.contiguous().data_ptr<float>(),
	  W, H, 
	//   means3D.contiguous().data<float>(),
	  out_means3D.contiguous().data_ptr<float>(),
	  sh.contiguous().data_ptr<float>(),
	  colors.contiguous().data_ptr<float>(),
	  flows_2d.contiguous().data_ptr<float>(),
	  opacities.contiguous().data_ptr<float>(),
	  ts.contiguous().data_ptr<float>(),
	  scales.data_ptr<float>(),
	  scales_t.data_ptr<float>(),
	  scale_modifier,
	  rotations.data_ptr<float>(),
	  rotations_r.data_ptr<float>(),
	  cov3D_precomp.contiguous().data_ptr<float>(),
	  viewmatrix.contiguous().data_ptr<float>(),
	  projmatrix.contiguous().data_ptr<float>(),
	  campos.contiguous().data_ptr<float>(),
	  timestamp,
      time_duration,
      rot_4d,
      gaussian_dim,
      force_sh_3d,
	  tan_fovx,
	  tan_fovy,
	  radii.contiguous().data_ptr<int>(),
	  means3D_static.contiguous().data_ptr<float>(),
	  sh_static.contiguous().data_ptr<float>(),
	  opacities_static.contiguous().data_ptr<float>(),
	  scales_static.contiguous().data_ptr<float>(),
	  rotations_static.contiguous().data_ptr<float>(),
	  radii_static.contiguous().data_ptr<int>(),
	  reinterpret_cast<char*>(geomBuffer.contiguous().data_ptr()),
	  reinterpret_cast<char*>(binningBuffer.contiguous().data_ptr()),
	  reinterpret_cast<char*>(imageBuffer.contiguous().data_ptr()),
	  reinterpret_cast<char*>(sampleBuffer.contiguous().data_ptr()),
	  dL_dout_color.contiguous().data_ptr<float>(),
	  dL_dout_invdepth.contiguous().data_ptr<float>(),
	  dL_dout_depth.contiguous().data_ptr<float>(),
	  dL_dout_mask.contiguous().data_ptr<float>(),
	  dL_dout_flow.contiguous().data_ptr<float>(),
	  dL_dmeans2D.contiguous().data_ptr<float>(),
	  dL_dconic.contiguous().data_ptr<float>(),  
	  dL_dopacity.contiguous().data_ptr<float>(),
	  dL_dcolors.contiguous().data_ptr<float>(),
	  dL_dmeans3D.contiguous().data_ptr<float>(),
	  dL_dcov3D.contiguous().data_ptr<float>(),
	  dL_dsh.contiguous().data_ptr<float>(),
	  dL_dflows.contiguous().data_ptr<float>(),
	  dL_dts.contiguous().data_ptr<float>(),
	  dL_dscales.contiguous().data_ptr<float>(),
	  dL_dscales_t.contiguous().data_ptr<float>(),
	  dL_drotations.contiguous().data_ptr<float>(),
	  dL_drotations_r.contiguous().data_ptr<float>(),
	  dL_dmeans2D_static.contiguous().data_ptr<float>(),
	  dL_dconic_static.contiguous().data_ptr<float>(),
	  dL_dopacity_static.contiguous().data_ptr<float>(),
	  dL_dmeans3D_static.contiguous().data_ptr<float>(),
	  dL_dcov3D_static.contiguous().data_ptr<float>(),
	  dL_dcolors_static.contiguous().data_ptr<float>(),
	  dL_dsh_static.contiguous().data_ptr<float>(),
	  dL_dscales_static.contiguous().data_ptr<float>(),
	  dL_drotations_static.contiguous().data_ptr<float>(),
	  debug);
  }

  return std::make_tuple(dL_dmeans2D, dL_dcolors, dL_dopacity, dL_dmeans3D, dL_dcov3D,
        dL_dsh, dL_dflows, dL_dts, dL_dscales, dL_dscales_t, dL_drotations, dL_drotations_r, 
		dL_dmeans2D_static, dL_dopacity_static, dL_dmeans3D_static, dL_dsh_static, dL_dscales_static, dL_drotations_static);
}

torch::Tensor markVisible(
		torch::Tensor& means3D,
		torch::Tensor& viewmatrix,
		torch::Tensor& projmatrix)
{ 
  const int P = means3D.size(0);
  
  torch::Tensor present = torch::full({P}, false, means3D.options().dtype(at::kBool));
 
  if(P != 0)
  {
	CudaRasterizer::Rasterizer::markVisible(P,
		means3D.contiguous().data_ptr<float>(),
		viewmatrix.contiguous().data_ptr<float>(),
		projmatrix.contiguous().data_ptr<float>(),
		present.contiguous().data_ptr<bool>());
  }
  
  return present;
}