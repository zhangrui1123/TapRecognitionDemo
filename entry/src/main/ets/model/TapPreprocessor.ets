const CHANNELS: number = 6;

/**
 * 2nd-order Butterworth high-pass @ 100Hz, 0.5Hz cutoff.
 * Coefficients match scipy.signal.butter(2, 0.5/50, 'high') used in training.
 */
export class TrainingHighPass {
  private readonly b0: number = 0.9780304792065597;
  private readonly b1: number = -1.9560609584131194;
  private readonly b2: number = 0.9780304792065597;
  private readonly a1: number = -1.9555782403150352;
  private readonly a2: number = 0.9565436765112031;
  private x1: Float32Array = new Float32Array(CHANNELS);
  private x2: Float32Array = new Float32Array(CHANNELS);
  private y1: Float32Array = new Float32Array(CHANNELS);
  private y2: Float32Array = new Float32Array(CHANNELS);

  filter(x: Float32Array): Float32Array {
    const y = new Float32Array(CHANNELS);
    for (let c = 0; c < CHANNELS; c++) {
      const yn = this.b0 * x[c] + this.b1 * this.x1[c] + this.b2 * this.x2[c]
        - this.a1 * this.y1[c] - this.a2 * this.y2[c];
      this.x2[c] = this.x1[c];
      this.x1[c] = x[c];
      this.y2[c] = this.y1[c];
      this.y1[c] = yn;
      y[c] = yn;
    }
    return y;
  }

  reset(): void {
    this.x1.fill(0);
    this.x2.fill(0);
    this.y1.fill(0);
    this.y2.fill(0);
  }
}
