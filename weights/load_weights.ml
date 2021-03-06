open Owl
open Hdf5_caml

module M = Owl_computation_cpu_engine.Make(Dense.Ndarray.S)
module Compiler = Owl_neural_compiler.Make(M)
open Compiler.Neural
open Compiler.Neural.Graph
module AD = Compiler.Neural.Algodiff

module N = Dense.Ndarray.Generic

let id_block input kernel_size filters stage block input_layer =
  let suffix = string_of_int stage ^ block ^ "_branch" in
  let conv_name = "res" ^ suffix in
  let bn_name = "bn" ^ suffix in
  let f1, f2, f3 = filters in
  let x =
    input_layer
    |> conv2d [|1; 1; input; f1|] [|1; 1|] ~padding:VALID ~name:(conv_name^"2a")
    |> normalisation ~axis:3 ~name:(bn_name^"2a")
    |> activation Activation.Relu

    |> conv2d [|kernel_size; kernel_size; f1; f2|] [|1; 1|]
         ~padding:SAME ~name:(conv_name^"2b")
    |> normalisation ~axis:3 ~name:(bn_name^"2b")
    |> activation Activation.Relu

    |> conv2d [|1; 1; f2; f3|] [|1; 1|] ~padding:VALID ~name:(conv_name^"2c")
    |> normalisation ~axis:3 ~name:(bn_name^"2c") in

  add [|x; input_layer|]
  |> activation Activation.Relu

let conv_block input kernel_size filters strides stage block input_layer =
  let suffix = string_of_int stage ^ block ^ "_branch" in
  let conv_name = "res" ^ suffix in
  let bn_name = "bn" ^ suffix in
  let f1, f2, f3 = filters in
  let x =
    input_layer
    |> conv2d [|1; 1; input; f1|] strides ~padding:VALID ~name:(conv_name^"2a")
    |> normalisation ~axis:3 ~name:(bn_name^"2a")
    |> activation Activation.Relu

    |> conv2d [|kernel_size; kernel_size; f1; f2|] [|1; 1|]
         ~padding:SAME ~name:(conv_name^"2b")
    |> normalisation ~axis:3 ~name:(bn_name^"2b")
    |> activation Activation.Relu

    |> conv2d [|1; 1; f2; f3|] [|1; 1|] ~padding:VALID ~name:(conv_name^"2c")
    |> normalisation ~axis:3 ~name:(bn_name^"2c") in

  let shortcut =
    input_layer
    |> conv2d [|1; 1; input; f3|] strides ~name:(conv_name^"1")
    |> normalisation ~axis:3 ~name:(bn_name^"1") in

  add [|x; shortcut|]
  |> activation Activation.Relu

let resnet50 img_size nb_classes =
  input [|img_size; img_size; 3|]
  |> padding2d [|[|3; 3|]; [|3; 3|]|] ~name:"conv1_pad"
  |> conv2d [|7; 7; 3; 64|] [|2; 2|] ~padding:VALID ~name:"conv1"
  |> normalisation ~axis:3 ~name:"bn_conv1"
  |> activation Activation.Relu
  |> max_pool2d [|3; 3|] [|2; 2|]

  |> conv_block 64 3 (64, 64, 256) [|1; 1|] 2 "a"
  |> id_block 256 3 (64, 64, 256) 2 "b"
  |> id_block 256 3 (64, 64, 256) 2 "c"

  |> conv_block 256 3 (128, 128, 512) [|2; 2|] 3 "a"
  |> id_block 512 3 (128, 128, 512) 3 "b"
  |> id_block 512 3 (128, 128, 512) 3 "c"
  |> id_block 512 3 (128, 128, 512) 3 "d"

  (* Here should be the change for ResNet101. *)
  |> conv_block 512 3 (256, 256, 1024) [|2; 2|] 4 "a"
  |> id_block 1024 3 (256, 256, 1024) 4 "b"
  |> id_block 1024 3 (256, 256, 1024) 4 "c"
  |> id_block 1024 3 (256, 256, 1024) 4 "d"
  |> id_block 1024 3 (256, 256, 1024) 4 "e"
  |> id_block 1024 3 (256, 256, 1024) 4 "f"

  |> conv_block 1024 3 (512, 512, 2048) [|2; 2|] 5 "a"
  |> id_block 2048 3 (512, 512, 2048) 5 "b"
  |> id_block 2048 3 (512, 512, 2048) 5 "c"

  |> global_avg_pool2d (* include_top *) ~name:"avg_pool"
  |> linear ~act_typ:Activation.(Softmax 1) nb_classes ~name:"fc1000"
  |> get_network

let fname = "resnet50_owl.hdf5"
let h5_file = H5.open_rdonly fname

let conv2d_W = "_W:0"
let conv2d_b = "_b:0"
let bn_beta = "_beta:0"
let bn_gamma = "_gamma:0"
let bn_mu = "_running_mean:0"
let bn_std = "_running_std:0"
let lin_W = "_W:0"
let lin_b = "_b:0"

let () =
  let nn = resnet50 224 1000 in
  Graph.init nn;
  Array.iter (fun n ->
      let param = Neuron.save_weights n.neuron in
      if Neuron.to_name n.neuron = "conv2d" then (
        let w = H5.read_float_genarray h5_file (n.name ^ conv2d_W) C_layout in
        let b = H5.read_float_genarray h5_file (n.name ^ conv2d_b) C_layout in
        let w = N.cast_d2s w in
        let b = N.cast_d2s b in
        param.(0) <- M.Symbol.pack_arr w |> AD.pack_arr;
        param.(1) <- M.Symbol.pack_arr b |> AD.pack_arr;
        Neuron.load_weights n.neuron param
      )
      else if Neuron.to_name n.neuron = "normalisation" then (
        let b = H5.read_float_genarray h5_file (n.name ^ bn_beta) C_layout in
        let g = H5.read_float_genarray h5_file (n.name ^ bn_gamma) C_layout in
        let mu = H5.read_float_genarray h5_file (n.name ^ bn_mu) C_layout in
        let std = H5.read_float_genarray h5_file (n.name ^ bn_std) C_layout in
        let b = N.cast_d2s b in
        let g = N.cast_d2s g in
        let mu = N.cast_d2s mu in
        let std = N.cast_d2s std in
        let len = Dense.Ndarray.S.shape b in
        let b = Dense.Ndarray.S.reshape b [|1;1;1;len.(0)|] in
        let len = Dense.Ndarray.S.shape g in
        let g = Dense.Ndarray.S.reshape g [|1;1;1;len.(0)|] in
        let len = Dense.Ndarray.S.shape mu in
        let mu = Dense.Ndarray.S.reshape mu [|1;1;1;len.(0)|] in
        let len = Dense.Ndarray.S.shape std in
        let std = Dense.Ndarray.S.reshape std [|1;1;1;len.(0)|] in
        param.(0) <- M.Symbol.pack_arr b |> AD.pack_arr;
        param.(1) <- M.Symbol.pack_arr g |> AD.pack_arr;
        param.(2) <- M.Symbol.pack_arr mu |> AD.pack_arr;
        param.(3) <- M.Symbol.pack_arr std |> AD.pack_arr;
        Neuron.load_weights n.neuron param
      )
      else if Neuron.to_name n.neuron = "linear" then (
        let w = H5.read_float_genarray h5_file (n.name ^ lin_W) C_layout in
        let b = H5.read_float_genarray h5_file (n.name ^ lin_b) C_layout in
        let w = N.cast_d2s w in
        let b = N.cast_d2s b in
        let b_dim = Array.append [|1|] (Dense.Ndarray.S.shape b) in
        let b = Dense.Ndarray.S.reshape b b_dim in
        param.(0) <- M.Symbol.pack_arr w |> AD.pack_arr;
        param.(1) <- M.Symbol.pack_arr b |> AD.pack_arr;
        Neuron.load_weights n.neuron param
      )
    ) nn.topo;
  Graph.save_weights nn "resnet.weights";
  H5.close h5_file

