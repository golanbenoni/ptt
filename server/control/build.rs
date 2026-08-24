fn main() {
    println!("cargo:rerun-if-changed=../../proto/control.proto");
    println!("cargo:rerun-if-changed=../../proto/media.proto");
    tonic_prost_build::configure()
        .build_client(false)
        .build_server(true)
        .compile_protos(
            &["../../proto/control.proto", "../../proto/media.proto"],
            &["../../proto"],
        )
        .expect("compile frozen control protocol");
}
